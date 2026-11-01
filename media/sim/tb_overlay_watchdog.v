`timescale 1ns/1ps
module tb_overlay_watchdog;
 reg clk=0,rst=1,link=1,session_reset=0,sd=1,catalog=1,found=1;
 reg image_idle=1,image_valid=1,render_idle=1,storage_idle=1,subtitle_busy=0,emergency=0,ui=0;
 wire file_start,file_abort,begin_req,abort_req,word_valid,source_ok,source_failed,busy,load_done;
 wire [31:0] file_cluster,file_size,file_limit,begin_object,word_data;
 reg begin_ack=0,begin_ready=0,begin_failed=0,file_busy=0;
 reg [7:0] file_data=0;reg file_valid=0,file_done=0,file_ok=0,word_ready=1,applied=0;
 integer begin_count=0;reg begin_req_d=0,abort_seen=0;
 always #5 clk=~clk;
 always @(posedge clk) begin
  if(rst) begin begin_ack<=0;begin_req_d<=0;begin_count<=0;abort_seen<=0;end
  else begin
   begin_req_d<=begin_req;
   begin_ack<=begin_req && !begin_req_d;
   if(begin_req && !begin_req_d) begin_count<=begin_count+1;
   if(abort_req) abort_seen<=1;
  end
 end
 sd_overlay_controller #(.WATCHDOG_CYCLES(32)) dut(
  .clk(clk),.rst(rst),.link_up(link),.session_reset(session_reset),.sd_ready(sd),
  .catalog_done(catalog),.overlay_found(found),.overlay_cluster(32'd3),.overlay_size(32'd12342),
  .image_idle(image_idle),.image_valid(image_valid),.render_image_transport_idle(render_idle),.storage_idle(storage_idle),
  .subtitle_busy(subtitle_busy),.emergency_hold(emergency),.ui_active(ui),
  .file_start(file_start),.file_cluster(file_cluster),.file_size(file_size),.file_read_limit(file_limit),
  .file_abort(file_abort),.file_busy(file_busy),.file_data(file_data),.file_valid(file_valid),
  .file_done(file_done),.file_ok(file_ok),.file_ready(),
  .begin_req(begin_req),.begin_ack(begin_ack),.begin_ready(begin_ready),.begin_failed(begin_failed),
  .begin_object(begin_object),.abort_req(abort_req),.word_valid(word_valid),.word_data(word_data),
  .word_ready(word_ready),.source_ok(source_ok),.source_failed(source_failed),.applied(applied),
  .busy(busy),.load_done(load_done));
 initial begin
  repeat(4) @(negedge clk);rst=0;
  repeat(500) @(negedge clk);
  if(busy || !load_done || begin_count!=2 || !abort_seen)
    $fatal(1,"watchdog recovery failed, busy=%b done=%b begin_count=%0d abort=%b",busy,load_done,begin_count,abort_seen);
  repeat(100) @(negedge clk);
  if(busy || begin_count!=2) $fatal(1,"failed overlay did not retire cleanly");
  $display("*** PASS *** missing OVL_READY times out, aborts, retries once, then releases busy");
  $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
