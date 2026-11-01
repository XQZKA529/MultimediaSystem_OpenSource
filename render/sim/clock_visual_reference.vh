// Independent literal text + software AA atlas oracle.
 function [7:0] clock_character;
  input integer col,row;reg [255:0] line;
  begin line="                                ";case(row)
   0:line=" CLOCK                          ";1:line=" YEAR           2000            ";
   2:line=" MONTH          02              ";3:line=" DAY            29              ";
   4:line=" HOUR           23              ";5:line=" MINUTE         59              ";
   6:line=" SECOND         59              ";7:line=" APPLY                          ";
   8:line="2/8 MOVE 4/6 -/+ 5 APPLY # BACK ";endcase
   clock_character=line[(31-col)*8 +: 8];end
 endfunction
 function [23:0] clock_coverage;
  input [23:0] bg;input integer a;integer w;reg [7:0] r,g,b;
  begin w=a==0 ? 0:a==1 ? 1:a==2 ? 3:4;
   r=(255*w+bg[23:16]*(4-w))/4;g=(255*w+bg[15:8]*(4-w))/4;b=(255*w+bg[7:0]*(4-w))/4;
   clock_coverage={r,g,b};end
 endfunction
 function [23:0] clock_golden;
  input integer px,py;input [23:0] base;
  reg [79:0] date;reg [63:0] times;reg [7:0] ch;reg [23:0] bg;
  integer dx,dy,col,row,cov;reg plate,card,border,text,high;
  begin date="2026-10-14";times="12:34:56";ch=32;dx=0;dy=0;high=0;text=0;
   plate=px>=8 && px<144 && py>=8 && py<60;card=clock_reference_editing && px>=446 && px<834 && py>=286 && py<434;
   border=(plate && (px==8 || px==143 || py==8 || py==59)) || (card && (px==446 || px==833 || py==286 || py==433));
   if(px>=16 && px<136 && py>=16 && py<32) begin text=1;dx=px-16;dy=py-16;col=dx/12;ch=date[(9-col)*8 +: 8];end
   else if(px>=16 && px<112 && py>=36 && py<52) begin text=1;dx=px-16;dy=py-36;col=dx/12;ch=times[(7-col)*8 +: 8];end
   else if(card && px>=448 && px<832 && py>=288 && py<432) begin text=1;dx=px-448;dy=py-288;col=dx/12;row=dy/16;high=row==3;ch=clock_character(col,row);end
   clock_golden=base;if(plate || card) begin
    clock_golden={1'b0,base[23:17],1'b0,base[15:9],1'b0,base[7:1]};
    if(border) clock_golden=24'h949494;
    else if(text) begin bg={1'b0,base[23:17],1'b0,base[15:9],1'b0,base[7:1]};
     if(high) bg={2'd0,base[23:18],2'd0,base[15:10],2'd0,base[7:2]}+24'h404040;
     cov=reference_alpha(ch,dx%12,dy%16);clock_golden=clock_coverage(bg,cov);end
   end
  end
 endfunction
