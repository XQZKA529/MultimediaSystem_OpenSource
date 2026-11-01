// VESA DDC/CI Get/Set VCP 0x10. No monitor-specific tables.
// 0=probing/updating, 1=verified hardware control, 2=RGB fallback.
module ddcci_brightness #(
    parameter integer CLK_HZ=75_000_000,
    parameter integer I2C_HZ=50_000,
    parameter integer STARTUP_MS=250,
    parameter integer GAP_MS=50,
    parameter integer RETRY_MS=100,
    parameter integer REPROBE_MS=5000
)(input wire clk,rst,input wire [3:0] level,
  output reg [1:0] mode,output wire [3:0] rgb_level,
  input wire scl_in,sda_in,output wire scl_low,sda_low);
    localparam BOOT=0,GET_START=1,GET_WAIT=2,READ_START=3,READ_WAIT=4,
               SET_START=5,SET_WAIT=6,PAUSE=7,IDLE=8,FAILED=9,
               CALC_PRODUCT=10,CALC_INIT=11,CALC_DIV=12;
    reg [3:0] state,next_state;
    reg [31:0] delay_count;
    reg [1:0] attempts;
    reg verifying,hardware_active;
    reg [3:0] applied_level,request_level;
    reg [15:0] maximum,target;
    reg start,read_transaction;
    reg [3:0] write_count;
    reg [55:0] tx_bytes;
    wire busy,done,error;
    wire [87:0] reply;
    wire [3:0] safe_level=(level>=1 && level<=10) ? level:4'd10;
    // DDC is slow: use a 20-cycle exact divider rather than a long pixel-clock path.
    reg [19:0] product,dividend,quotient;
    reg [3:0] remainder;
    reg [4:0] divide_count;
    wire [4:0] trial_remainder={remainder,dividend[19]};
    wire quotient_bit=(trial_remainder>=5'd10);
    // Reply checksum starts with virtual host address 0x50.
    wire [7:0] reply_xor=8'h50 ^ reply[87:80] ^ reply[79:72] ^ reply[71:64] ^
        reply[63:56] ^ reply[55:48] ^ reply[47:40] ^ reply[39:32] ^
        reply[31:24] ^ reply[23:16] ^ reply[15:8] ^ reply[7:0];
    // Layout: source,length,opcode,result,VCP,type,max_hi,max_lo,cur_hi,cur_lo,checksum.
    // Correct field slices are decoded explicitly below.
    wire [15:0] max_value=reply[39:24],current_value=reply[23:8];
    wire valid_reply=reply[87:80]==8'h6e && reply[79:72]==8'h88 &&
        reply[71:64]==8'h02 && reply[63:56]==0 && reply[55:48]==8'h10 &&
        reply[47:40]==0 && reply_xor==0 && max_value!=0 && current_value<=max_value;
    assign rgb_level=hardware_active ? 4'd10:safe_level;
    ddc_i2c_master #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ)) u_i2c(
        .clk(clk),.rst(rst),.start(start),.read_transaction(read_transaction),
        .write_count(write_count),.tx_bytes(tx_bytes),.busy(busy),.done(done),.error(error),
        .rx_bytes(reply),.scl_in(scl_in),.sda_in(sda_in),.scl_low(scl_low),.sda_low(sda_low));
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=BOOT;next_state<=GET_START;delay_count<=(CLK_HZ/1000)*STARTUP_MS;
            attempts<=0;verifying<=0;hardware_active<=0;mode<=0;
            applied_level<=0;request_level<=10;maximum<=100;target<=100;
            start<=0;read_transaction<=0;write_count<=0;tx_bytes<=0;
            product<=0;dividend<=0;quotient<=0;remainder<=0;divide_count<=0;
        end else begin
            start<=0;
            case(state)
                BOOT:if(delay_count==0) state<=GET_START;else delay_count<=delay_count-1'b1;
                GET_START:if(!busy) begin
                    // XOR checksum 6e ^ 51 ^ 82 ^ 01 ^ 10 = ac.
                    tx_bytes<=56'h51820110ac0000;write_count<=5;read_transaction<=0;start<=1;state<=GET_WAIT;
                end
                GET_WAIT:if(done) begin
                    if(error) state<=FAILED;
                    else begin delay_count<=(CLK_HZ/1000)*GAP_MS;next_state<=READ_START;state<=PAUSE;end
                end
                READ_START:if(!busy) begin read_transaction<=1;start<=1;state<=READ_WAIT;end
                READ_WAIT:if(done) begin
                    if(error || !valid_reply || (verifying && current_value!=target)) state<=FAILED;
                    else if(verifying) begin
                        hardware_active<=1;mode<=1;applied_level<=request_level;attempts<=0;
                        verifying<=0;delay_count<=(CLK_HZ/1000)*GAP_MS;next_state<=IDLE;state<=PAUSE;
                    end else begin
                        maximum<=max_value;hardware_active<=1;mode<=0;
                        delay_count<=(CLK_HZ/1000)*GAP_MS;next_state<=CALC_PRODUCT;state<=PAUSE;
                    end
                end
                CALC_PRODUCT:begin
                    product<={4'd0,maximum}*{16'd0,safe_level};request_level<=safe_level;mode<=0;state<=CALC_INIT;
                end
                CALC_INIT:begin
                    dividend<=product+20'd5;quotient<=0;remainder<=0;divide_count<=20;state<=CALC_DIV;
                end
                CALC_DIV:begin
                    dividend<=dividend<<1;quotient<={quotient[18:0],quotient_bit};
                    remainder<=quotient_bit ? trial_remainder-5'd10:trial_remainder;
                    divide_count<=divide_count-1'b1;
                    if(divide_count==1) begin target<={quotient[14:0],quotient_bit};state<=SET_START;end
                end
                SET_START:if(!busy) begin
                    tx_bytes<={8'h51,8'h84,8'h03,8'h10,target,
                               (8'ha8 ^ target[15:8] ^ target[7:0])};
                    write_count<=7;read_transaction<=0;start<=1;state<=SET_WAIT;
                end
                SET_WAIT:if(done) begin
                    if(error) state<=FAILED;
                    else begin verifying<=1;delay_count<=(CLK_HZ/1000)*GAP_MS;next_state<=GET_START;state<=PAUSE;end
                end
                PAUSE:if(delay_count==0) state<=next_state;else delay_count<=delay_count-1'b1;
                IDLE:if(safe_level!=applied_level) begin attempts<=0;state<=CALC_PRODUCT;end
                FAILED:begin
                    if(attempts==2) begin
                        hardware_active<=0;mode<=2;attempts<=0;verifying<=0;
                        delay_count<=(CLK_HZ/1000)*REPROBE_MS;next_state<=GET_START;state<=PAUSE;
                    end else begin
                        attempts<=attempts+1'b1;verifying<=0;
                        delay_count<=(CLK_HZ/1000)*RETRY_MS;next_state<=GET_START;state<=PAUSE;
                    end
                end
                default:state<=BOOT;
            endcase
        end
    end
endmodule
