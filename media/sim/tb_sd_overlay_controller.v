`timescale 1ns/1ps
module tb_sd_overlay_controller #(parameter integer WD_CYCLES=64);
 reg clk=0,rst=1,link=1,sreset=0,sd=1,cat=1,found=1,image_idle=1,image_valid=1,render_idle=0,storage_idle=1,sub_busy=0,em=0,ui=0;
 reg [31:0] cluster=32'h1234,size=12342;
 wire fstart,fabort;wire [31:0] fc,fs,limit;reg fbusy=0;reg [7:0] fd=0;reg fv=0,done=0,fok=1;wire fr;
 wire breq;reg back=0,bready=0,bfailed=0;wire [31:0] object_id;wire abort_req,wvalid,sok,sfailed,busy,load_done;wire [31:0] wdata;reg wready=1,applied=0;
 integer words=0,i,x,y,failures=0;reg file_abort_seen=0;
 reg [7:0] bmp[0:12341];
 sd_overlay_controller #(.WATCHDOG_CYCLES(WD_CYCLES)) dut(.clk(clk),.rst(rst),.link_up(link),.session_reset(sreset),.sd_ready(sd),
  .catalog_done(cat),.overlay_found(found),.overlay_cluster(cluster),.overlay_size(size),
  .image_idle(image_idle),.image_valid(image_valid),.render_image_transport_idle(render_idle),.storage_idle(storage_idle),.subtitle_busy(sub_busy),.emergency_hold(em),.ui_active(ui),
  .file_start(fstart),.file_cluster(fc),.file_size(fs),.file_read_limit(limit),.file_abort(fabort),.file_busy(fbusy),
  .file_data(fd),.file_valid(fv),.file_done(done),.file_ok(fok),.file_ready(fr),
  .begin_req(breq),.begin_ack(back),.begin_ready(bready),.begin_failed(bfailed),.begin_object(object_id),.abort_req(abort_req),
  .word_valid(wvalid),.word_data(wdata),.word_ready(wready),.source_ok(sok),.source_failed(sfailed),.applied(applied),.busy(busy),.load_done(load_done));
 always #5 clk=~clk;
 always @(posedge clk) if(!rst && fabort) begin fbusy<=0;file_abort_seen<=1;end
 task tick;input integer n;begin repeat(n) @(negedge clk);end endtask
 task send_byte;input [7:0] v;begin
   while(!fr) @(negedge clk);
   fd=v;fv=1;@(negedge clk);fv=0;
 end endtask
 always @(posedge clk) if(!rst && wvalid && wready) begin
   if(wdata!==32'h07e0f800) begin $display("overlay pair %0d wrong: %h",words,wdata);failures=failures+1;end
   words=words+1;
 end
 initial begin
   for(i=0;i<12342;i=i+1) bmp[i]=0;
   bmp[0]="B";bmp[1]="M";bmp[2]=8'h36;bmp[3]=8'h30;
   bmp[10]=54;bmp[14]=40;bmp[18]=64;bmp[22]=64;bmp[26]=1;bmp[28]=24;
   bmp[34]=0;bmp[35]=8'h30;
   for(y=0;y<64;y=y+1) for(x=0;x<64;x=x+1) begin
     if(x[0]==0) begin bmp[54+(y*64+x)*3]=0;bmp[55+(y*64+x)*3]=0;bmp[56+(y*64+x)*3]=255;end
     else begin bmp[54+(y*64+x)*3]=0;bmp[55+(y*64+x)*3]=255;bmp[56+(y*64+x)*3]=0;end
   end
   tick(4);rst=0;tick(20);
   if(breq || busy) $fatal(1,"overlay claimed the shared scheduler before render finished the current image");
   render_idle=1;wait(breq);if(!object_id[31]) $fatal(1,"overlay object aliases the 24-bit main-image namespace");
   @(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);
   if(fc!=cluster || fs!=size || limit!=12342) $fatal(1,"wrong reserved file descriptor");
   tick(2);
   for(i=0;i<12342;i=i+1) send_byte(bmp[i]);
   @(negedge clk);done=1;fok=1;tick(1);done=0;
   wait(sok);if(words!=2048 || failures!=0) $fatal(1,"stream words=%0d bad=%0d",words,failures);
   @(negedge clk);applied=1;tick(1);applied=0;tick(3);
   if(busy || !load_done) $fatal(1,"successful overlay did not retire");
   found=1;sreset=1;tick(1);sreset=0;wait(breq);@(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);tick(2);
   for(i=0;i<12342;i=i+1) send_byte(bmp[i]);
   @(negedge clk);done=1;fok=1;tick(1);done=0;wait(sok);found=0;tick(WD_CYCLES+10);
   if(busy || !load_done) $fatal(1,"missing APPLIED response held overlay busy");
   found=1;sreset=1;tick(1);sreset=0;wait(breq);@(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);
   @(negedge clk);fbusy=1;found=0;file_abort_seen=0;tick(WD_CYCLES+20);
   if(!file_abort_seen || busy || !load_done) $fatal(1,"stalled SD read did not abort and release busy");
   found=0;sreset=1;tick(1);sreset=0;tick(100);if(breq || busy) begin $display("missing state req=%b busy=%b done=%b",breq,busy,load_done);$fatal(1,"missing overlay should be skipped");end
   found=1;bmp[18]=63;sreset=1;tick(1);sreset=0;wait(breq);@(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);tick(2);
   for(i=0;i<54;i=i+1) send_byte(bmp[i]);
   wait(sfailed);if(!abort_req && !fabort) begin tick(2);if(!fabort) $fatal(1,"malformed dimensions were not aborted");end
   tick(4);sreset=1;tick(1);sreset=0;bmp[18]=64;found=1;
   wait(breq);@(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);fbusy=1;tick(2);
   em=1;tick(1);if(!fabort) $fatal(1,"emergency did not cancel active SD read");em=0;fbusy=0;tick(5);
   if(!breq || !busy) $fatal(1,"overlay load did not retry after emergency recovery");
   @(negedge clk);bfailed=1;tick(1);bfailed=0;tick(5);
   if(!breq || !busy) $fatal(1,"render-side reset/error did not trigger one retransfer");
   @(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);fbusy=1;tick(2);
   @(negedge clk);done=1;fok=0;tick(1);done=0;fbusy=0;wait(sfailed);tick(4);
   if(breq || busy) $fatal(1,"SD read failure was not retired cleanly");
   sreset=1;tick(1);sreset=0;wait(breq);@(negedge clk);back=1;tick(1);back=0;bready=1;tick(1);bready=0;wait(fstart);fbusy=1;tick(2);
   @(negedge clk);done=1;fok=1;tick(1);done=0;fbusy=0;wait(sfailed);tick(4);
   if(breq || busy) $fatal(1,"truncated BMP stream was not rejected");
   $display("*** PASS *** tb_sd_overlay_controller: waits for render presentation before scheduler claim; BMP stream, error, timeout and retry recovery");$finish;
 end
 initial begin #5000000;$fatal(1,"timeout");end
endmodule
