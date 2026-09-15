module clock (
   input                     reset,
   input                     clk_sys,
   output                    ce_3m58_p,
   output                    ce_3m58_n
);

   logic [2:0] div6;
   always_ff @(posedge clk_sys)
   if (reset)
      div6 <= 3'd0;
   else 
      if (div6==5)
         div6 <= 3'd0;
      else
         div6 <= div6 + 3'd1;

   assign ce_3m58_p = (div6 == 3'd0);
   assign ce_3m58_n = (div6 == 3'd3);  

endmodule
