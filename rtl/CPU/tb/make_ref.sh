#!/bin/sh
# Vytvoří zmrazenou referenční kopii TV80 do ref/ (moduly s předponou REF_).
# Lockstep test (run_lockstep.sh) pak porovnává upravený TV80 s touhle kopií.
#
#   wsl.exe -- bash rtl/CPU/tb/make_ref.sh            # kopie z pracovního stromu
#   SRC_REF=<commit> bash rtl/CPU/tb/make_ref.sh     # kopie z commitu v gitu
#
# Kopie se commituje. Přegeneruje se jen tehdy, když se změna chování TV80
# vědomě přijme jako nový základ.
set -e

cd "$(dirname "$0")"
mkdir -p ref

for f in tv80a tv80 tv80_alu tv80_mcode tv80_reg; do
   if [ -n "$SRC_REF" ]; then
      git show "$SRC_REF:rtl/CPU/$f.sv" > "ref/.tmp.sv"
   else
      cp "../$f.sv" "ref/.tmp.sv"
   fi
   {
      echo "// ZMRAŽENÁ REFERENČNÍ KOPIE rtl/CPU/$f.sv — needitovat, generuje make_ref.sh"
      echo "// Zdroj: ${SRC_REF:-pracovní strom} $(date +%Y-%m-%d)"
      sed -E 's/\b(TV80a|TV80|TV80_Reg|TV80_ALU|TV80_MCode)\b/REF_\1/g' "ref/.tmp.sv"
   } > "ref/ref_$f.sv"
done
rm -f ref/.tmp.sv
echo "ref/ vytvořeno: $(ls ref)"
