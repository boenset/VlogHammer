#!/bin/bash
#
#  Vlog-Hammer -- A Verilog Synthesis Regression Test
#
#  Copyright (C) 2013  Clifford Wolf <clifford@clifford.at>
#  
#  Permission to use, copy, modify, and/or distribute this software for any
#  purpose with or without fee is hereby granted, provided that the above
#  copyright notice and this permission notice appear in all copies.
#  
#  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
#  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
#  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
#  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
#  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

keep=false
refresh=false
quick=false

while true; do
	if [ "$1" = "-keep" ]; then
		keep=true
		shift
		continue
	fi
	if [ "$1" = "-refresh" ]; then
		refresh=true
		shift
		continue
	fi
	if [ "$1" = "-quick" ]; then
		quick=true
		shift
		continue
	fi
	break
done

if [ $# -ne 1 ]; then
	echo "Usage: $0 <job_name>" >&2
	exit 1
fi

job="$1"
set -ex --

test -n "$SYN_LIST"
test -n "$SIM_LIST"
test -n "$ISE_SETTINGS"
test -n "$MODELSIM_DIR"

rm -rf temp/report_${job}
mkdir -p temp/report_${job}
cd temp/report_${job}

cp ../../rtl/$job.v rtl.v
cp rtl.v syn_rtl.v

html_notes=""
in_lists="all"

for p in ${SYN_LIST}; do
	if grep -q VLOGHAMMER_SYN_ERROR ../../syn_$p/$job.v; then
		html_notes="$html_notes
<div class=\"note\">Synthesis of $job using <i>$p</i> failed!</div>"
		in_lists="$in_lists $p"
		SYN_LIST="$( echo " ${SYN_LIST} " | sed "s, $p , ,; s,^ ,,; s, \$,,;" )"
	else
		cp ../../syn_$p/$job.v syn_$p.v
		cp ../../cache_$p/$job.il syn_$p.il
	fi
done

{
	egrep '^ *(module|input|output)' rtl.v | sed 's/ y/ y1, y2/'
	sed "/^ *module/ ! d; s/.*(//; s/[a-w0-9]\+/.\0(\0)/g; s/y[0-9]*/.\0(\01)/g; s/^/  ${job}_1 ${job}_1 (/;" rtl.v
	sed "/^ *module/ ! d; s/.*(//; s/[a-w0-9]\+/.\0(\0)/g; s/y[0-9]*/.\0(\02)/g; s/^/  ${job}_2 ${job}_2 (/;" rtl.v
	echo "endmodule"
} > top.v

echo -n > fail_patterns.txt
for p in ${SYN_LIST} rtl; do
for q in ${SYN_LIST} rtl; do
	if [ "$p" = "$q" ]; then
		echo PASS > result.${p}.${q}.txt
		continue
	fi
	if test -f result.${q}.${p}.txt; then
		cp result.${q}.${p}.txt result.${p}.${q}.txt
		continue
	fi

	{
		if [ $p = rtl ]; then
			echo "read_verilog rtl.v"
		else
			echo "read_ilang syn_$p.il"
		fi
		echo "rename $job ${job}_1"

		if [ $q = rtl ]; then
			echo "read_verilog rtl.v"
		else
			echo "read_ilang syn_$q.il"
		fi
		echo "rename $job ${job}_2"

		echo "read_verilog top.v"
		echo "proc; opt_clean"
		echo "flatten ${job}"

		echo "! touch test.$p.$q.input_ok"

		ports=$( grep ^module top.v | tr '()' '::' | cut -f2 -d: | tr -d ' ' )
		if $quick; then
			echo "sat -ignore_div_by_zero -timeout 2 -verify-no-timeout -show $ports -prove y1 y2 ${job}"
		else
			echo "sat -ignore_div_by_zero -timeout 20 -verify-no-timeout -show $ports -prove y1 y2 ${job}"
		fi
	} > test.$p.$q.ys

	if yosys -l test.$p.$q.log test.$p.$q.ys; then
		if grep TIMEOUT test.$p.$q.log; then
			echo TIMEOUT > result.${p}.${q}.txt
		else
			echo PASS > result.${p}.${q}.txt
		fi
	else
		echo $( grep '^ *\\[a-xz][0-9]* ' test.$p.$q.log | gawk '{ print $4; }' | tr -d '\n' ) >> fail_patterns.txt
		echo FAIL > result.${p}.${q}.txt
	fi

	# this fails if an error was encountered before the 'sat' command
	rm test.$p.$q.input_ok
done; done

extra_patterns="$( grep '^ *// *PATTERN:' rtl.v | cut -f2- -d: )"
bits=$( echo $( grep '^ *input' rtl.v | sed 's/.*\[//; s/:.*/+1+/;' )0 | bc; )
inputs=$( echo $( grep '^ *input' rtl.v | sed 's,.* ,,; y/;/,/; s/\n//;' ) | sed 's/, *$//;' )
for x in 1 2 3 4 5 6 7 8 9 0; do
	extra_patterns="$extra_patterns $( echo $job$x | sha1sum | gawk "{ print \"160'h\" \$1; }" )"
done

{
	echo "module testbench;"

	sed -r '/^ *input / !d; s/input/reg/;' rtl.v
	for p in ${SYN_LIST} rtl; do
		sed -r "/^ *output / !d; s/output/wire/; s/ y;/ ${p}_y;/;" rtl.v
		sed "/^ *module/ ! d; s/.*(//; s/[a-w0-9]\+/.\0(\0)/g; s/y[0-9]*/.\0(${p}_\0)/g; s/^/  ${job}_$p uut_$p (/;" rtl.v
	done

	y_type=$( grep '^ *output ' rtl.v | sed 's,^ *output ,,; s, y;.*,,;' )

	echo "  function $y_type apply_rtl_undef;"
	echo "    input $y_type y;"
	echo "    integer i;"
	echo "    begin"
	echo "      for (i = 0; i <= $( echo "$y_type" | tr '[' ':' | cut -f2 -d: ); i=i+1)"
	echo "        apply_rtl_undef[i] = rtl_y[i] === 1'bx ? 1'bx : y[i];"
	echo "    end"
	echo "  endfunction"

	index=0
	echo "  initial begin"
	for pattern in $bits\'b0 ~$bits\'b0 $( sort -u fail_patterns.txt | sed "s/^/$bits'b/;" ) $extra_patterns; do
		echo "    { $inputs } <= $pattern; #1;"
		for p in ${inputs//,/}; do
			echo "    \$display(\"++PAT++ %d $p %b %d\", $index, uut_rtl.$p, uut_rtl.$p);"
		done
		for p in ${SYN_LIST} rtl; do
			echo "    \$display(\"++RPT++ %d $(echo $inputs | sed -r 's,[^ ]+,%b,g;') %b $p\", $index, $inputs, apply_rtl_undef(${p}_y));"
		done
		for p in ${SYN_LIST} rtl; do
			echo "    \$display(\"++VAL++ %d $p %b %d\", $index, ${p}_y, ${p}_y);"
		done
		echo "    \$display(\"++RPT++ ----\");"
		index=$(( index + 1 ))
	done
	echo "    \$display(\"++OK++\");"
	echo "    \$finish;"
	echo "  end"

	echo "endmodule"

	for p in ${SYN_LIST} rtl; do
		sed "s/^module ${job}/module ${job}_${p}/; /^\`timescale/ d;" < syn_$p.v
	done

	cat ../../scripts/cells_cyclone_iii.v
	cat ../../scripts/cells_xilinx_7.v
} > testbench.v

{
	echo "module ${job}_tb;"
	sed -r '/^ *input / !d; s/input/reg/;' rtl.v
	sed -r "/^ *output / !d; s/output/wire/;" rtl.v
	sed "/^ *module/ ! d; s/.*(/  ${job} uut (/;" rtl.v

	echo "  task test_pattern;"
	echo "    input [5:0] index;"
	echo "    input [$bits-1:0] pattern;"
	echo "    begin"
	echo "      { $inputs } <= pattern; #1;"
	echo "      \$display(\"++RPT++ %d $(echo $inputs | sed -r 's,[^ ]+,%b,g;') %b\", index, $inputs, y);"
	echo "    end"
	echo "  endtask"

	index=0
	echo "  initial begin"
	for pattern in $bits\'b0 ~$bits\'b0 $( sort -u fail_patterns.txt | sed "s/^/$bits'b/;" ) $extra_patterns; do
		printf '    test_pattern( %2d, %s );\n' $index "$pattern"
		index=$(( index + 1 ))
	done
	echo "  end"
	echo "endmodule"
} > simple_tb.v

if [[ " ${SIM_LIST} " == *" isim "* ]]; then
	(
	set +x
	. ${ISE_SETTINGS}
	set -x
	vlogcomp testbench.v
	fuse -o testbench_isim testbench
	{ echo "run all"; echo "exit"; } > run-all.tcl
	timeout 120 ./testbench_isim -tclbatch run-all.tcl | tee sim_isim.log
	)
fi

if [[ " ${SIM_LIST} " == *" modelsim "* ]]; then
	${MODELSIM_DIR}/vlib work
	${MODELSIM_DIR}/vlog testbench.v
	${MODELSIM_DIR}/vsim -c -do "run; exit" work.testbench | tee sim_modelsim.log
fi

if [[ " ${SIM_LIST} " == *" icarus "* ]]; then
	if iverilog -o testbench_icarus testbench.v; then
		timeout 120 ./testbench_icarus | tee sim_icarus.log
	else
		echo -n > sim_icarus.log
	fi
fi

if [[ " ${SIM_LIST} " == *" yosim "* ]]; then
	{
		echo "read_verilog rtl.v"
		echo "rename ${job} ${job}_rtl"
		for p in ${SYN_LIST}; do
			echo "read_ilang syn_${p}.il"
			echo "rename ${job} ${job}_${p}"
		done
		echo -n "eval -vloghammer_report ${job}_ "
		echo rtl ${SYN_LIST} | tr ' ' , | tr '\n' ' '
		echo $inputs | tr -d ' ' | tr '\n' ' '
		echo $bits\'b0 ~$bits\'b0 $( sort -u fail_patterns.txt | sed "s/^/$bits'b/;" ) $extra_patterns | tr ' ' ','
	} > testbench_yosys.ys

	if ! yosys -l sim_yosim.log -q testbench_yosys.ys; then
		echo -n > sim_yosim.log
	fi
fi

for p in ${SIM_LIST}; do
	if ! grep -q '\+\+OK\+\+' sim_$p.log; then
		html_notes="$html_notes
<div class=\"note\">Simulation of $job using <i>$p</i> failed!</div>"
		in_lists="$in_lists $p"
		SIM_LIST="$( echo " ${SIM_LIST} " | sed "s, $p , ,; s,^ ,,; s, \$,,;" )"
	fi
done

for p in ${SYN_LIST} rtl; do
for q in ${SIM_LIST}; do
	echo $( grep '++RPT++' sim_$q.log | sed 's,.*++RPT++ ,,' | grep " $p\$" | gawk '{ print $(NF-1); }' | md5sum | gawk '{ print $1; }' ) > result.${p}.${q}.txt
done; done

echo "#00ff00" > color_PASS.txt
echo "#33aa33" > color_TIMEOUT.txt
echo "#ff0000" > color_FAIL.txt

goodsim="modelsim"
if cmp result.rtl.modelsim.txt result.rtl.isim.txt; then
	echo "#00ff00" > color_$( cat result.rtl.modelsim.txt ).txt
elif cmp result.rtl.modelsim.txt result.rtl.icarus.txt; then
	echo "#00ff00" > color_$( cat result.rtl.modelsim.txt ).txt
elif cmp result.rtl.modelsim.txt result.rtl.yosim.txt; then
	echo "#00ff00" > color_$( cat result.rtl.modelsim.txt ).txt
elif cmp result.rtl.isim.txt result.rtl.yosim.txt && cmp result.rtl.icarus.txt result.rtl.yosim.txt; then
	echo "#00ff00" > color_$( cat result.rtl.yosim.txt ).txt
	goodsim="yosim"
else
	goodcode=$( egrep -h '^[a-f0-9]+$' result.*.txt | sort | uniq -c | sort -rn | gawk 'NR == 1 { a=$1; x=$2; } NR == 2 { b=$1; } END { if (a>b+2) print x; else print "NO_SIM_COMMON"; }' )
	echo "#00ff00" > color_$goodcode.txt
	for q in ${SIM_LIST}; do
		if grep -q $goodcode result.rtl.$q.txt; then
			goodsim="$q"
		fi
	done
fi

if test -f result.rtl.$goodsim.txt; then
	for q in ${SIM_LIST}; do
		if ! cmp result.rtl.$goodsim.txt result.rtl.$q.txt; then
			in_lists="$in_lists $q"
		fi
	done
	for q in ${SYN_LIST}; do
		if ! cmp result.rtl.$goodsim.txt result.$q.$goodsim.txt; then
			in_lists="$in_lists $q"
		fi
		if test -f result.$q.yosim.txt && ! cmp result.$q.$goodsim.txt result.$q.yosim.txt; then
			in_lists="$in_lists yosim"
		fi
	done
fi

{
	cat <<- EOT
		<style><!--

		.info { margin: 1em; }
		.info:before { content: "Info: "; font-weight:bold; }

		.note { margin: 1em; }
		.note:before { content: "Error Note: "; font-weight:bold; }

		.overviewtab { margin: 0.7em; }
		.overviewtab th { width: 100px; }

		.valuestab { border-collapse:collapse; border: 2px solid black; }

		.valuestab th,
		.valuestab td { border-collapse:collapse; border: 1px solid black; }

		.valuestab th,
		.valuestab td { padding-left: 0.2em; padding-right: 0.2em; }

		.valuestab tr:nth-child(2n-1) { background: #eee; }
		.valuestab tr:nth-child(1) { background: #ccc; }
		.valuestab td.valsimlist { max-width: 300px;  background: #f8f8f8; }
		.valuestab td:nth-last-child(1) { font-family: monospace; text-align: right; min-width: 100px; }
		.valuestab td:nth-last-child(2) { font-family: monospace; text-align: right; min-width: 100px; }
		.valuestab { margin: 1em; }

		.testbench { margin: 1em; border: 5px dashed gray; padding: 1em; max-width: 900px; }

		//--></style>
	EOT

	if $refresh; then
		echo '<!-- REFRESH:BEGIN -->'
		echo "<body onload=\"pingfade();\">"
		echo '<meta http-equiv="refresh" content="2"/>'
		echo '<script language="JavaScript"><!--'
		echo 'var pingfadecount = 0;'
		echo 'function pingfade() {'
		echo '	if (pingfadecount++ < 30) {'
		echo '		var k = 1 - Math.exp(-pingfadecount*0.3);'
		echo '		var s = (255*k+256).toString(16).slice(1, 3);'
		echo '		document.getElementById("x").bgColor = "#" + s + s + s;'
		echo '		window.setTimeout(pingfade, 30);'
		echo '	} else'
		echo '		document.getElementById("x").bgColor = "#ffffff";'
		echo '}'
		echo '//--></script>'
		echo '<!-- REFRESH:END -->'
	fi

	echo "<h3>Vlog-Hammer Report: $job</h3>"
	echo "<!-- LISTS:" $( echo $in_lists | tr ' ' '\n' | sort -u ) "-->"
	echo "<!-- REPORT:BEGIN -->"
	echo "<div class=\"info\">This report is part of the following lists: <i>" \
			$( echo $in_lists | tr ' ' '\n' | sort -u ) "</i></div>$html_notes"
	echo "<table class=\"overviewtab\" border>"
	echo "<tr><th id=\"x\"></th>"
	for q in ${SYN_LIST} rtl ${SIM_LIST}; do
		echo "<th>$q</th>"
	done
	echo "</tr>"
	for p in ${SYN_LIST} rtl; do
		echo "<tr><th>$p</th>"
		for q in ${SYN_LIST} rtl ${SIM_LIST}; do
			read result < result.${p}.${q}.txt
			if ! test -f color_$result.txt; then
				case $( ls color_*.txt | wc -l ) in
					3) echo "#ffff00" > color_$result.txt ;;
					4) echo "#ff00ff" > color_$result.txt ;;
					5) echo "#00ffff" > color_$result.txt ;;
					*) echo "#888888" > color_$result.txt ;;
				esac
			fi
			echo "<!-- REPORT-DATA: $( printf "%-8s %-8s %-8.8s" $p $q $result ) --><td align=\"center\" bgcolor=\"$( cat color_$result.txt )\">$( echo $result | cut -c1-8 )</td>"
		done
		echo "</tr>"
	done
	echo "</table>"

	echo "<pre class=\"testbench\"><small>$( perl -pe 's/([<>&])/"&#".ord($1).";"/eg;' rtl.v <( echo ) simple_tb.v |
			perl -pe 's!([^\w#]|^)([\w'\'']+|\$(display|unsigned|signed)|".*?")!$x = $1; $y = $2; sprintf("%s<span style=\"color: %s;\">%s</span>", $x, $y =~ /^[0-9"]/ ? "#663333;" :
			$y =~ /^(module|input|wire|reg|output|assign|signed|begin|end|task|endtask|initial|endmodule|\$(display|unsigned|signed))$/ ? "#008800;" : "#000088;", $y)!eg' )</small></pre>"

	echo "<!-- VALUES:BEGIN -->"
	python ../../scripts/valtab.py ${SIM_LIST}
	echo "<!-- VALUES:END -->"
	echo "<!-- REPORT:END -->"
} > report.html

mkdir -p ../../report
cp report.html ../../report/${job}.html

if ! $keep; then
	rm -rf ../report_${job}
fi
echo READY.

