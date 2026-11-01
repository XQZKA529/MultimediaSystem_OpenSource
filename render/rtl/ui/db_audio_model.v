`include "../pkg/video_bmp_params.vh"
`include "../pkg/osd_model_bus.vh"
// Builds the local drawing model from ACTUALLY PLAYED frames, including seek base.
// Division and time formatting are background sequential work, outside scanout.
module db_audio_model #(parameter BAR_W=`VBP_OSD_BAR_W,parameter PIX_HZ=`VBP_PIX_CLK_HZ)(
    input wire clk,rst,vs,input wire [31:0] position,total,
    input wire playing,paused,input wire [`OSD_M_SPEC_W-1:0] spectrum,
    output wire [`OSD_M_W-1:0] model
);
    reg vs_d;
    reg [2:0] state;
    reg [42:0] dividend,quotient;
    reg [32:0] remainder;
    reg [31:0] divisor,seconds_work,total_work;
    reg [5:0] bit_count;
    reg [15:0] cur_digits,dur_digits,digits;
    reg [9:0] fill;
    reg [127:0] model_r;
    reg [1:0] beat;
    wire tick4,lvl1;
    osd_timebase #(.CLK_FREQ_HZ(PIX_HZ)) u_time(.video_clk(clk),.rst(rst),.o_tick4(tick4),.o_tick1(),.o_lvl1(lvl1));
    wire [32:0] trial={remainder[31:0],dividend[42]};
    wire subtract_ok=trial>={1'b0,divisor};
    wire [103:0] text={8'h30+{4'd0,dur_digits[3:0]},8'h30+{4'd0,dur_digits[7:4]},8'h3a,
        8'h30+{4'd0,dur_digits[11:8]},8'h30+{4'd0,dur_digits[15:12]},8'h20,8'h2f,8'h20,
        8'h30+{4'd0,cur_digits[3:0]},8'h30+{4'd0,cur_digits[7:4]},8'h3a,
        8'h30+{4'd0,cur_digits[11:8]},8'h30+{4'd0,cur_digits[15:12]}};
    function [15:0] next_second;
        input [15:0] d;
        begin
            next_second=d;
            if(d[3:0]<9) next_second[3:0]=d[3:0]+1'b1;
            else begin
                next_second[3:0]=0;
                if(d[7:4]<5) next_second[7:4]=d[7:4]+1'b1;
                else begin
                    next_second[7:4]=0;
                    if(d[11:8]<9) next_second[11:8]=d[11:8]+1'b1;
                    else begin next_second[11:8]=0;next_second[15:12]=d[15:12]+1'b1;end
                end
            end
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin vs_d<=0;state<=0;dividend<=0;quotient<=0;remainder<=0;divisor<=0;
            seconds_work<=0;total_work<=0;bit_count<=0;cur_digits<=0;dur_digits<=0;
            digits<=0;fill<=0;model_r<=0;beat<=0;end
        else begin
            vs_d<=vs;if(tick4 && playing && !paused) beat<=beat+1'b1;
            if(vs && !vs_d) begin
                model_r<={9'd0,lvl1,paused,playing,text,beat,fill};
                if(state==0) begin
                    dividend<=position*BAR_W;divisor<=total;quotient<=0;remainder<=0;
                    bit_count<=42;state<=1;
                    seconds_work<=position>287952000 ? 287952000:position;
                    total_work<=total>287952000 ? 287952000:total;digits<=0;
                end
            end
            case(state)
                1:begin
                    dividend<=dividend<<1;quotient<={quotient[41:0],subtract_ok};
                    remainder<=subtract_ok ? trial-divisor:trial;
                    if(bit_count==0) state<=2;else bit_count<=bit_count-1'b1;
                end
                2:begin
                    fill<=divisor==0 ? 0 : quotient>BAR_W ? BAR_W:quotient[9:0];state<=3;
                end
                3:if(seconds_work>=48000) begin seconds_work<=seconds_work-48000;digits<=next_second(digits);end
                  else begin cur_digits<=digits;digits<=0;seconds_work<=total_work;state<=4;end
                4:if(seconds_work>=48000) begin seconds_work<=seconds_work-48000;digits<=next_second(digits);end
                  else begin dur_digits<=digits;state<=0;end
                default:;
            endcase
        end
    end
    assign model[127:0]=model_r;assign model[`OSD_M_SPEC]=spectrum;
endmodule
