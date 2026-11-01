// Single-master DDC transaction engine, 7-bit address 0x37.
// Both pads are open drain; wait for actual SCL high (clock stretching).
// tx_bytes is MSB first, up to 7 bytes; reads return 11 bytes MSB first.
module ddc_i2c_master #(
    parameter integer CLK_HZ=75_000_000,
    parameter integer I2C_HZ=50_000,
    parameter integer TIMEOUT_MS=20
)(input wire clk,rst,start,read_transaction,
  input wire [3:0] write_count,input wire [55:0] tx_bytes,
  output reg busy,done,error,output reg [87:0] rx_bytes,
  input wire scl_in,sda_in,output reg scl_low,sda_low);
    localparam integer HALF=(CLK_HZ/(2*I2C_HZ)<2) ? 2:CLK_HZ/(2*I2C_HZ);
    localparam integer TIMEOUT=(CLK_HZ/1000)*TIMEOUT_MS;
    localparam IDLE=0,START_HIGH=1,START_LOW=2,BIT_LOW=3,BIT_HIGH=4,
               ACK_LOW=5,ACK_HIGH=6,STOP_LOW=7,STOP_HIGH=8,STOP_RELEASE=9;
    reg [3:0] state;
    reg reading,address_phase;
    (* async_reg="true" *) reg scl1,scl2,sda1,sda2;
    // tick is cleared at HALF-1. Timeout age increments once on the
    // timeout edge too, then holds TIMEOUT+1 while idle.
    localparam TICK_BITS=$clog2(HALF);
    localparam AGE_BITS=(TIMEOUT>=0 && TIMEOUT<32'h7fffffff) ?
        (($clog2(TIMEOUT+2)>0) ? $clog2(TIMEOUT+2):1):32;
    reg [TICK_BITS-1:0] tick;
    reg [AGE_BITS-1:0] age;
    reg [3:0] byte_index,nwrite;
    reg [2:0] bit_index;
    reg [7:0] shift;
    reg [55:0] outgoing;
    always @(posedge clk or posedge rst)
        if(rst) begin scl1<=1;scl2<=1;sda1<=1;sda2<=1;end
        else begin scl1<=scl_in;scl2<=scl1;sda1<=sda_in;sda2<=sda1;end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;scl_low<=0;sda_low<=0;busy<=0;done<=0;error<=0;
            rx_bytes<=0;tick<=0;age<=0;byte_index<=0;bit_index<=7;
            shift<=0;outgoing<=0;reading<=0;address_phase<=0;nwrite<=0;
        end else begin
            done<=0;
            if(busy) age<=age+1'b1;
            if(busy && age>=TIMEOUT) begin
                // Release a stuck bus; never block video or wait forever.
                scl_low<=0;sda_low<=0;busy<=0;done<=1;error<=1;state<=IDLE;
            end else case(state)
                IDLE:if(start) begin
                    busy<=1;error<=0;age<=0;tick<=0;rx_bytes<=0;
                    reading<=read_transaction;nwrite<=write_count;outgoing<=tx_bytes;
                    byte_index<=0;address_phase<=1;bit_index<=7;
                    shift<=read_transaction ? 8'h6f:8'h6e;state<=START_HIGH;
                end
                START_HIGH:if(scl2 && sda2) begin
                    if(tick==HALF-1) begin sda_low<=1;tick<=0;state<=START_LOW;end
                    else tick<=tick+1'b1;
                end else tick<=0;
                START_LOW:if(tick==HALF-1) begin
                    scl_low<=1;sda_low<=!shift[7];tick<=0;state<=BIT_LOW;
                end else tick<=tick+1'b1;
                BIT_LOW:if(tick==HALF-1) begin scl_low<=0;tick<=0;state<=BIT_HIGH;end
                        else tick<=tick+1'b1;
                BIT_HIGH:if(scl2) begin
                    if(tick==HALF-1) begin
                        scl_low<=1;tick<=0;
                        if(reading && !address_phase) shift<={shift[6:0],sda2};
                        if(bit_index==0) begin
                            // Master ACKs all reply bytes except the last one.
                            sda_low<=reading && !address_phase && byte_index!=10;
                            state<=ACK_LOW;
                        end else begin
                            bit_index<=bit_index-1'b1;
                            sda_low<=(!reading || address_phase) ? !shift[bit_index-1'b1]:1'b0;
                            state<=BIT_LOW;
                        end
                    end else tick<=tick+1'b1;
                end else tick<=0;
                ACK_LOW:if(tick==HALF-1) begin scl_low<=0;tick<=0;state<=ACK_HIGH;end
                        else tick<=tick+1'b1;
                ACK_HIGH:if(scl2) begin
                    if(tick==HALF-1) begin
                        scl_low<=1;tick<=0;bit_index<=7;
                        if((!reading || address_phase) && sda2) begin
                            error<=1;sda_low<=1;state<=STOP_LOW;
                        end else if(address_phase) begin
                            address_phase<=0;shift<=reading ? 8'd0:outgoing[55:48];
                            outgoing<=outgoing<<8;sda_low<=reading ? 1'b0:!outgoing[55];state<=BIT_LOW;
                        end else if(reading) begin
                            rx_bytes<={rx_bytes[79:0],shift};
                            if(byte_index==10) begin sda_low<=1;state<=STOP_LOW;end
                            else begin byte_index<=byte_index+1'b1;shift<=0;sda_low<=0;state<=BIT_LOW;end
                        end else if(byte_index+1>=nwrite) begin sda_low<=1;state<=STOP_LOW;end
                        else begin
                            byte_index<=byte_index+1'b1;shift<=outgoing[55:48];outgoing<=outgoing<<8;
                            sda_low<=!outgoing[55];state<=BIT_LOW;
                        end
                    end else tick<=tick+1'b1;
                end else tick<=0;
                STOP_LOW:if(tick==HALF-1) begin scl_low<=0;tick<=0;state<=STOP_HIGH;end
                         else tick<=tick+1'b1;
                STOP_HIGH:if(scl2) begin
                    if(tick==HALF-1) begin sda_low<=0;tick<=0;state<=STOP_RELEASE;end
                    else tick<=tick+1'b1;
                end else tick<=0;
                STOP_RELEASE:if(tick==HALF-1) begin busy<=0;done<=1;state<=IDLE;tick<=0;end
                             else tick<=tick+1'b1;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
