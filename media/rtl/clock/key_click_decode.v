// Debounced events -> mutually exclusive short/double click.
// Singles are deferred until the release-to-second-press window expires.
module key_click_decode #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer DBL_WIN_MS=300
)(input wire clk,rst,enable,cancel,
  input wire ev_press,ev_release,ev_hold,
  output reg single_pulse,double_pulse);
    localparam IDLE=0,DOWN=1,WAIT_SECOND=2,DRAIN=3;
    localparam integer LIMIT=(CLK_FREQ_HZ/1000)*DBL_WIN_MS;
    reg [1:0] state;
    reg [31:0] count;
    reg pressed;
    always @(posedge clk or posedge rst) begin
        if(rst) begin state<=IDLE;count<=0;pressed<=0;single_pulse<=0;double_pulse<=0;end
        else begin
            single_pulse<=0;double_pulse<=0;
            if(ev_press) pressed<=1;
            if(ev_release) pressed<=0;
            if(!enable || cancel) begin
                count<=0;
                state<=(ev_press || (pressed && !ev_release)) ? DRAIN:IDLE;
            end else case(state)
                IDLE:if(ev_press) state<=DOWN;
                DOWN:if(ev_hold) state<=DRAIN;
                     else if(ev_release) begin count<=LIMIT;state<=WAIT_SECOND;end
                WAIT_SECOND:if(ev_press) begin double_pulse<=1;count<=0;state<=DRAIN;end
                            else if(count<=1) begin single_pulse<=1;count<=0;state<=IDLE;end
                            else count<=count-1'b1;
                DRAIN:if(ev_release || !pressed) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
