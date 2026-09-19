//============================================================================
//  tv80_dbg_pkg — rozhraní debuggeru Z80 (doc/z80-debugger.md)
//
//  dbg_in_t  příkazy a nastavení (od přenosu / registrového prostoru)
//  dbg_out_t stav (k přenosu / registrovému prostoru)
//  Pulzní signály trvají jeden takt clk_sys.
//============================================================================

package tv80_dbg_pkg;

   localparam int NBP = 9;                 // počet breakpointů

   // Typ breakpointu, bitová maska (víc typů najednou)
   localparam logic [4:0] BP_EXEC  = 5'b00001;  // provedení instrukce na adrese
   localparam logic [4:0] BP_MRD   = 5'b00010;  // čtení paměti (bez fetche opkódu)
   localparam logic [4:0] BP_MWR   = 5'b00100;  // zápis do paměti
   localparam logic [4:0] BP_IORD  = 5'b01000;  // čtení I/O
   localparam logic [4:0] BP_IOWR  = 5'b10000;  // zápis I/O

   typedef struct packed {
      logic [4:0]  kind;     // {IOWR, IORD, MWR, MRD, EXEC}, 0 = vypnuto
      logic [15:0] addr;
      logic [15:0] amask;    // 1 = bit se porovnává (I/O: jen [7:0])
      logic [7:0]  data;
      logic [7:0]  dmask;    // 1 = bit se porovnává, 0 = hodnota nerozhoduje
   } bp_t;

   // Důvod zastavení
   typedef enum logic [2:0] {
      R_NONE = 3'd0,         // běží
      R_STOP = 3'd1,         // příkaz stop
      R_STEP = 3'd2,         // dokončený krok
      R_EXEC = 3'd3,         // breakpoint EXEC
      R_ACC  = 3'd4          // breakpoint čtení/zápisu (paměť nebo I/O)
   } reason_t;

   typedef struct packed {
      logic        stop;         // pulz: zastavit na nejbližší hranici
      logic        run;          // pulz: rozběhnout
      logic        step;         // pulz: jedna instrukce a zastavit
      logic        step_noint;   // při kroku maskovat INT
      logic        dirset;       // pulz: nahrát dir do registrů (jen při zastavení)
      logic [211:0] dir;
      bp_t [NBP-1:0] bp;
      logic        mem_req;      // pulz: přístup do paměti (jen při zastavení)
      logic        mem_we;
      logic [15:0] mem_addr;
      logic [7:0]  mem_wdata;
   } dbg_in_t;

   typedef struct packed {
      logic        stopped;
      reason_t     reason;
      logic [NBP-1:0] hit;       // které breakpointy se trefily
      logic [15:0] hit_addr;     // adresa přístupu (u EXEC = PC)
      logic [7:0]  hit_data;     // data přístupu
      logic [15:0] hit_pc;       // PC instrukce, která zásah způsobila
      logic [211:0] regs;        // snímek registrů (rozložení viz tv80.sv)
      logic        mem_busy;
      logic [7:0]  mem_rdata;
   } dbg_out_t;

endpackage
