module sd_card_sdio #(
    parameter integer CLK_FREQ_HZ     = 100_000_000,
    parameter integer SD_CLK_DIV_INIT = 125,          // 400 kHz
    parameter integer SD_CLK_DIV_FAST = 2,            // 25 MHz 默认速度
    parameter integer SD_CLK_DIV_HS   = 1,            // 50 MHz 高速
    parameter integer SAMPLE_DLY      = 0,
    parameter integer SPEED_TARGET    = 1,            // 1=尝试切到 50MHz High Speed
    parameter integer OVERLAY_FIXTURE = 0,
    parameter integer IMAGE_SWITCH_FIXTURE = 0,
    // Timing model (diagnostic TB only; defaults reproduce the old stub):
    //   HEAD_CLKS  = command + response + data-start-token before a burst
    //   LATENCY_CLKS = card read-access latency after the command (per burst)
    //   BYTE_CLKS  = bus clocks per byte on the DAT bus
    //                (4-bit @25MHz on a 50MHz bus -> 4; 1-bit @25MHz -> 8)
    //   TAIL_CLKS  = CRC16 + end bit + inter-block gap after a burst
    parameter integer HEAD_CLKS = 0,
    parameter integer LATENCY_CLKS = 0,
    parameter integer BYTE_CLKS = 1,
    parameter integer TAIL_CLKS = 0
)(
    input  wire        clk,             // sd_card_clk = 100 MHz
    input  wire        rst,             // 高有效

    //====================== SD 物理引脚 ======================
    output wire        SD_CLK,
    inout  wire        SD_CMD,
    input  wire        SD_DAT0,
    input  wire        SD_DAT1,
    input  wire        SD_DAT2,
    input  wire        SD_DAT3,

    //====================== 状态（供上层判断与调试）======================
    output wire        sd_init_done,
    output wire        sd_init_error,
    output wire [7:0]  sd_init_err_code,   // 1=CMD8无响应 ... 8=CMD7 busy 9=CMD8坏响应
    output wire        sd_high_speed,      // 1 = 已切到 50MHz High Speed
    output wire [1:0]  sd_bus_width,       // 1 = 4-bit
    output wire        sd_is_sdhc,
    output wire [15:0] sd_card_rca,

    //====================== 通道 0：图像 ======================
    input  wire        ch0_req,
    input  wire [31:0] ch0_sector,
    input  wire [15:0] ch0_count,
    output wire        ch0_grant,
    output wire [7:0]  ch0_data,
    output wire        ch0_data_valid,
    output wire        ch0_end,
    output wire        ch0_error,

    //====================== 通道 1：预留（视频 / 音乐）======================
    input  wire        ch1_req,
    input  wire [31:0] ch1_sector,
    input  wire [15:0] ch1_count,
    output wire        ch1_grant,
    output wire [7:0]  ch1_data,
    output wire        ch1_data_valid,
    output wire        ch1_end,
    output wire        ch1_error,

    //====================== 调试 ======================
    output wire [4:0]  dbg_state,
    output wire [5:0]  dbg_resp_cmd,
    output wire [31:0] dbg_resp_arg,
    output wire [7:0]  dbg_switch_fn,
    output wire [15:0] dbg_clk_div
);
    assign SD_CLK=clk;assign SD_CMD=1'bz;
    assign sd_init_done=!rst;assign sd_init_error=0;assign sd_init_err_code=0;
    assign sd_high_speed=0;assign sd_bus_width=1;assign sd_is_sdhc=1;assign sd_card_rca=1;
    reg grant1=0,valid1=0,ending1=0,busy1=0;reg [7:0] data1=0;
    integer base1=0,pos1=0,total1=0;
    assign ch1_grant=grant1;assign ch1_data=data1;assign ch1_data_valid=valid1;assign ch1_end=ending1;assign ch1_error=0;
    assign dbg_state=0;assign dbg_resp_cmd=0;assign dbg_resp_arg=0;assign dbg_switch_fn=0;assign dbg_clk_div=2;
    reg grant=0,valid=0,ending=0,busy=0;reg [7:0] data=0;
    integer base=0,pos=0,total=0,file_reads=0;
    integer sectors_served=0,bytes_served=0;
    reg [31:0] head_left=0,pace_left=0,tail_left=0;
    assign ch0_grant=grant;assign ch0_data=data;assign ch0_data_valid=valid;assign ch0_end=ending;assign ch0_error=0;
    reg [7:0] disk[0:65535];
    task put16;input integer a;input [15:0] v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];end endtask
    task put32;input integer a;input [31:0] v;begin disk[a]=v[7:0];disk[a+1]=v[15:8];disk[a+2]=v[23:16];disk[a+3]=v[31:24];end endtask
    integer i;reg [87:0] name;
    integer fixture_count=0;
    reg [31:0] fixture_lbas[0:511];
    reg [7:0] fixture_bytes[0:262143];
    reg [8191:0] fixture_lba_path,fixture_byte_path;
    initial begin
        if($value$plusargs("CARD_COUNT=%d",fixture_count)) begin
            if(fixture_count<1 || fixture_count>512 ||
               !$value$plusargs("CARD_LBAS=%s",fixture_lba_path) ||
               !$value$plusargs("CARD_BYTES=%s",fixture_byte_path)) $fatal(1,"bad card capture arguments");
            $readmemh(fixture_lba_path,fixture_lbas,0,fixture_count-1);
            $readmemh(fixture_byte_path,fixture_bytes,0,fixture_count*512-1);
        end
        for(i=0;i<65536;i=i+1)disk[i]=0;
        // Valid FAT32 superfloppy; data_lba=65, root cluster=2, BMP cluster=3.
        put16(11,512);disk[13]=128;put16(14,1);disk[16]=1;
        put32(32,7000);put32(36,64);put32(44,2);disk[510]=8'h55;disk[511]=8'haa;
        put32(512,32'h0ffffff8);put32(516,32'h0fffffff);put32(520,32'h0fffffff);put32(524,32'h0fffffff);
        // Full 720p BMP occupies clusters 3..45, including 42 FAT transitions.
        for(i=3;i<45;i=i+1)put32(512+i*4,i+1);
        put32(512+45*4,32'h0fffffff);
        name="IMAGE   BMP";
        for(i=0;i<11;i=i+1)disk[65*512+i]=name[(10-i)*8+:8];
        disk[65*512+11]=8'h20;put16(65*512+26,3);put32(65*512+28,2764854);
        if(IMAGE_SWITCH_FIXTURE) begin
            put32(512+3*4,32'h0fffffff);
            put32(65*512+28,150);
            name="SECOND  BMP";
            for(i=0;i<11;i=i+1)disk[65*512+32+i]=name[(10-i)*8+:8];
            disk[65*512+43]=8'h20;put16(65*512+58,4);put32(65*512+60,150);
            if(IMAGE_SWITCH_FIXTURE==2) begin
                name="IMAGE   WAV";
                for(i=0;i<11;i=i+1)disk[65*512+64+i]=name[(10-i)*8+:8];
                disk[65*512+75]=8'h20;put16(65*512+90,6);put32(65*512+92,48044);
                name="IMAGE   TXT";
                for(i=0;i<11;i=i+1)disk[65*512+96+i]=name[(10-i)*8+:8];
                disk[65*512+107]=8'h20;put16(65*512+122,5);put32(65*512+124,3);
                name="SECOND  WAV";
                for(i=0;i<11;i=i+1)disk[65*512+128+i]=name[(10-i)*8+:8];
                disk[65*512+139]=8'h20;put16(65*512+154,8);put32(65*512+156,48044);
                name="SECOND  TXT";
                for(i=0;i<11;i=i+1)disk[65*512+160+i]=name[(10-i)*8+:8];
                disk[65*512+171]=8'h20;put16(65*512+186,7);put32(65*512+188,3);
                for(i=4;i<=8;i=i+1)put32(512+i*4,32'h0fffffff);
            end
        end
        if(OVERLAY_FIXTURE) begin
            name="overlay bmp";
            for(i=0;i<11;i=i+1)disk[65*512+32+i]=name[(10-i)*8+:8];
            disk[65*512+43]=8'h20;put16(65*512+58,46);put32(65*512+60,12342);
            put32(512+46*4,32'h0fffffff);
        end
    end
    function [7:0] read_byte;input integer addr;integer p,q,pixel,cluster,lo,hi,mid,slot;begin
        p=addr-193*512;
        q=addr-5697*512;
        if(fixture_count>0) begin
            lo=0;hi=fixture_count-1;slot=-1;
            while(lo<=hi) begin
                mid=(lo+hi)/2;
                if(fixture_lbas[mid]==addr/512) begin slot=mid;lo=hi+1;end
                else if(fixture_lbas[mid]<addr/512) lo=mid+1;
                else hi=mid-1;
            end
            if(slot<0) begin $display("uncaptured SD LBA=%0d",addr/512);$fatal(1,"uncaptured sector");end
            read_byte=fixture_bytes[slot*512+addr%512];
        end else if(IMAGE_SWITCH_FIXTURE && p>=0) begin
            cluster=3+p/(128*512);
            p=p%(128*512);
            if(IMAGE_SWITCH_FIXTURE==2 && (cluster==6 || cluster==8)) begin
                case(p)
                    0:read_byte="R";1:read_byte="I";2,3:read_byte="F";
                    4:read_byte=8'ha4;5:read_byte=8'hbb;
                    8:read_byte="W";9:read_byte="A";10:read_byte="V";11:read_byte="E";
                    12:read_byte="f";13:read_byte="m";14:read_byte="t";15:read_byte=" ";
                    16:read_byte=16;20:read_byte=1;22:read_byte=2;
                    24:read_byte=8'h80;25:read_byte=8'hbb;
                    28:read_byte=0;29:read_byte=8'hee;30:read_byte=2;
                    32:read_byte=4;34:read_byte=16;
                    36:read_byte="d";37:read_byte="a";38:read_byte="t";39:read_byte="a";
                    40:read_byte=8'h80;41:read_byte=8'hbb;
                    default:read_byte=p<44 ? 0:p[7:0];
                endcase
            end else if(IMAGE_SWITCH_FIXTURE==2 && (cluster==5 || cluster==7)) read_byte="S";
            else case(p)
                0:read_byte="B";1:read_byte="M";2:read_byte=150;
                10:read_byte=54;14:read_byte=40;18:read_byte=8;22:read_byte=4;
                26:read_byte=1;28:read_byte=24;
                default:read_byte=p<54 ? 0:p[7:0];
            endcase
        end else if(OVERLAY_FIXTURE && q>=0) begin
            pixel=(q-54)/3;
            case(q)
                0:read_byte="B";1:read_byte="M";
                2:read_byte=8'h36;3:read_byte=8'h30;
                10:read_byte=54;14:read_byte=40;18,22:read_byte=64;
                26:read_byte=1;28:read_byte=24;
                default:if(q<54) read_byte=0;
                    else case((q-54)%3)
                        0:read_byte=(pixel/64)^(pixel%64);
                        1:read_byte=(pixel/64)*4;
                        2:read_byte=(pixel%64)*4;
                    endcase
            endcase
        end else if(p<0) read_byte=disk[addr];
        else begin
            case(p)
                0:read_byte="B";1:read_byte="M";
                2:read_byte=8'h36;3:read_byte=8'h30;4:read_byte=8'h2a;
                10:read_byte=54;14:read_byte=40;
                18:read_byte=0;19:read_byte=5;22:read_byte=8'hd0;23:read_byte=2;
                26:read_byte=1;28:read_byte=24;
                default:read_byte=p<54 ? 0:p[7:0];
            endcase
        end
    end endfunction
    always @(posedge clk) begin
        grant1<=0;valid1<=0;ending1<=0;
        if(rst) busy1<=0;
        else if(IMAGE_SWITCH_FIXTURE==2 && ch1_req && !busy1) begin
            busy1<=1;grant1<=1;base1<=ch1_sector*512;pos1<=0;total1<=ch1_count*512;
        end else if(busy1) begin
            if(pos1<total1) begin data1<=read_byte(base1+pos1);valid1<=1;pos1<=pos1+1;end
            else begin ending1<=1;busy1<=0;end
        end
    end
    always @(posedge clk) begin
        grant<=0;valid<=0;ending<=0;
        if(rst) begin busy<=0;file_reads<=0;sectors_served<=0;bytes_served<=0;
            head_left<=0;pace_left<=0;tail_left<=0;end
        else if(ch0_req && !busy) begin
            busy<=1;grant<=1;base<=ch0_sector*512;pos<=0;total<=ch0_count*512;
            head_left<=HEAD_CLKS+LATENCY_CLKS;pace_left<=0;tail_left<=TAIL_CLKS;
            sectors_served<=sectors_served+ch0_count;
            if(ch0_sector>=193)file_reads<=file_reads+1;
        end else if(busy) begin
            if(head_left!=0) head_left<=head_left-1'b1;
            else if(pos<total) begin
                if(pace_left!=0) pace_left<=pace_left-1'b1;
                else begin
                    data<=read_byte(base+pos);valid<=1;pos<=pos+1;
                    pace_left<=(BYTE_CLKS<=1)?32'd0:BYTE_CLKS-1'b1;
                    bytes_served<=bytes_served+1;
                end
            end else if(tail_left!=0) tail_left<=tail_left-1'b1;
            else begin ending<=1;busy<=0;end
        end
    end
endmodule
