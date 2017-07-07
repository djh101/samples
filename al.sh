#!/bin/sh

# Place this file in the same directory as the pp folder.

# Set nat (number of layers)
if [ -z $1 ]; then
	printf "Enter a value for nat (number of layers): "
	read nat
else
	nat=$1
fi

# Set pw.x parameters
celldm1='5.4065'
celldm3='10'
verbosity='low'
tprnfor='false'
nbnd='8'
ecutwfc='55.0'
degauss='0.005'
forc_conv_thr='1.0d-3'
conv_thr='1.0d-7'
mixing_beta='0.7'
kpoints='16'

# Create directory for this run
i=1
while [ -d "al${nat}-${i}" ]
do
	((i=i+1))
done
dname="al${nat}-${i}"
mkdir "$dname"
cd "$dname"
mkdir temp

# Execute pw.x for SCF, NSCF, and BANDS
for calc in scf nscf bands
do
	time=$(date +"%T")
	case $calc in
		scf)
			echo "[${time}] Executing pw.x SCF..."
			restart_mode='from_scratch'
			;;
		nscf)
			echo "[${time}] Executing pw.x NSCF..."
			restart_mode='restart'
			;;
		bands)
			echo "[${time}] Executing pw.x BANDS..."
			restart_mode='restart'
			;;
	esac
	cat > al.${calc}.in <<- EOF
		&control
		  prefix = 'al',
		  calculation = '${calc}',
		  pseudo_dir = '../pp',
		  outdir = 'temp',
		  tprnfor = .${tprnfor}.,
		  forc_conv_thr = ${forc_conv_thr},
		  restart_mode = '${restart_mode}',
		  verbosity = '${verbosity}'
		/
		&system
		  ibrav = 4,
		  celldm(1) = ${celldm1},
		  celldm(3) = ${celldm3},
		  nat = ${nat},
		  ntyp = 1,
		  nbnd = ${nbnd},
		  ecutwfc = ${ecutwfc},
		  occupations = 'smearing',
		  smearing = 'gaussian',
		  degauss = ${degauss}
		/
		&electrons
		  conv_thr = ${conv_thr},
		  mixing_beta = ${mixing_beta}
		/
		ATOMIC_SPECIES
		  Al  26.982  Al.pz-vbc.UPF
		ATOMIC_POSITIONS alat
		  Al  0.0  0.0  0.0
		  $([ $nat -ge 2 ] && echo 'Al  0.0  0.577350  0.816497')
		  $([ $nat -eq 3 ] && echo 'Al  0.5  0.288675  1.632990')
		$(if [ "$calc" = "bands" ]; then
			echo "K_POINTS crystal_b"
			echo "4"
			echo "  0.50  0.00  0.00  30 !M"
			echo "  0.33  0.33  0.00  30 !K"
			echo "  0.00  0.00  0.00  30 !G"
			echo "  0.50  0.00  0.00  30 !M"
		else
			echo "K_POINTS automatic"
			echo "  $kpoints $kpoints 1 0 0 0"
		fi)
	EOF
	mpirun pw.x < al.${calc}.in > al.${calc}.out
	
	# Check if run crashed
	if [ -e 'CRASH' ]; then
		echo "pw.x has crashed. Exiting."
		exit 1
	fi
done

# Execute bands.x
time=$(date +"%T")
echo "[${time}] Executing bands.x..."
cat > al.bandx.in <<- EOF
	&bands
	  prefix = "al",
	  outdir = "temp",
	  filband = "bandx.dat"
	/
EOF
mpirun bands.x < al.bandx.in > al.bandx.out

# Fetch data from output
fermi=$(awk '/Fermi/ {print $5}' al.scf.out)
Emin=$(awk 'BEGIN{min=0} NR % 2 && NR != 1 {for(i=1;i<=NF;i++) if($i<min) min=$i} END{print min}' bandx.dat | perl -nl -MPOSIX -e 'print floor($_)')
Emax=$(awk 'BEGIN{max=0} NR % 2 && NR != 1 {for(i=1;i<=NF;i++) if($i>max) max=$i} END{print max}' bandx.dat | perl -nl -MPOSIX -e 'print ceil($_)')

printf "\nFermi Energy: %.3feV\n\n" "$fermi"

# Execute dos.x
time=$(date +"%T")
echo "[${time}] Executing dos.x..."
cat > al.dos.in <<- EOF
	&dos
	  outdir='temp',
	  prefix='al',
	  Emin=${Emin},
	  Emax=${Emax},
	  DeltaE=0.05,
	  fildos='dos.dat'
	/
EOF
mpirun dos.x < al.dos.in > al.dos.out

# Execute plotband.x
time=$(date +"%T")
echo "[${time}] Plotting band structure and density of states..."
plotband.x bandx.dat <<- EOF
	${Emin}, ${Emax}
	bands.gnu
	bands.ps
	${fermi}
	1, ${fermi}
EOF
cat bands.gnu.* > bands.gnu
rm bands.gnu.*

# Get x interval for plotting Fermi energy line
bmin=0
bmax=$(awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}' bands.gnu)
dmin=0
dmax=$(awk 'BEGIN{max=0} NR != 1 {if($2>max) max=$2} END{printf "%.3f", max}' dos.dat)

# Plot bands and density of states in gnuplot
gnuplot > bands.png <<- EOF
	set terminal pngcairo enhanced truecolor font ",9" dashlength 0.5 size 800,600
	set multiplot layout 1,2
	set label 1
	set arrow from ${bmin},${fermi} to ${bmax},${fermi} nohead dashtype 2 linecolor "grey"
	plot "bands.gnu" u 1:2 w l t "Bands"
	unset arrow
	set label 2
	set arrow from ${dmin},${fermi} to ${dmax},${fermi} nohead dashtype 2 linecolor "grey"
	plot [] [${Emin}:$(($Emax+1))] "dos.dat" u 2:1 w l t "DoS"
EOF

time=$(date +"%T")
echo "[${time}] Finished."
