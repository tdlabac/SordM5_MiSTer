module ga015 (
    input [15:0]        A,
    input [7:0]         D,
    input               RST_n,
    input               MRQ_n,
    input               IORQ_n,
    input               RD_n,
    input               WR_n,
        
    output              MWR_n,
    output              MRD_n,
    output              IORD_n,
    output              IOWR_n,
   
    output              CTC_n,
    output              CSR_n,
    output              CSW_n,
    output              SGC_n,
    output              ROM0_n,
    output              ROM1_n,
    output              ROM2_n,
    output              RAM0_n,
    output              RAM1_n,
    output              EXM_n,
    output              EXIOA_n,
    output              EXIOB_n,
    output              KB_n,
    output              PDT_n,
    output              STS_n,
    output              PSTB_n,
    output              PCOM_n
);


assign  ROM0_n = !(A[15:13] == 3'b000);         // 0000 - 1FFF
assign  ROM1_n = !(A[15:13] == 3'b001);         // 2000 - 3FFF
assign  ROM2_n = !(A[15:13] == 3'b010);         // 4000 - 5FFF
assign  EXM_n  = !(A[15:13] == 3'b011);         // 6000 - 6FFF
assign  RAM0_n = !(A[15:11] == 5'b01110);       // 7000 - 77FF
assign  RAM1_n = !(A[15:11] == 5'b01111);       // 7800 - 7FFF

assign  MRD_n  = MRQ_n || RD_n;
assign  MWR_n  = MRQ_n || WR_n;

assign  IORD_n  = IORQ_n || RD_n;
assign  IOWR_n  = IORQ_n || WR_n;

assign  CTC_n   = !(A[7:4] == 4'b0000) || IORQ_n;                // 00
assign  CSR_n   = !(A[7:4] == 4'b0001) || IORD_n;                // 10
assign  CSW_n   = !(A[7:4] == 4'b0001) || IOWR_n;                // 10
assign  SGC_n   = !(A[7:4] == 4'b0010) || IORQ_n;                // 20
assign  KB_n    = !(A[7:4] == 4'b0011) || IORQ_n || RD_n;        // 30
assign  STS_n   = !(A[7:4] == 4'b0101) || IORQ_n || RD_n;        // 50 čtení: páska, klávesa RESET
assign  PCOM_n  = !(A[7:4] == 4'b0101) || IORQ_n || WR_n;        // 50 zápis: bit 1 motor kazety
assign  EXIOA_n = !(A[7:4] == 4'b0110);                          // 60 IO 0x60

assign  EXIOB_n = '1;
assign  PDT_n   = '1;
assign  PSTB_n  = '1;

endmodule
