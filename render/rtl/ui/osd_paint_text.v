// Native AA time painter: ASCII/coordinates register then coverage lookup.
`include "../pkg/osd_model_bus.vh"
module osd_paint_text #(
    parameter integer SCALE = 2,       // 点阵放大倍数（2 ⇒ 字符格 12×16）
    parameter integer CHARS = `OSD_TXT_CHARS,
    parameter SHARED_GLASS=0
)(
    input  wire        clk,
    input  wire        rst,              // 高有效
    input  wire [10:0] lx,               // 局部列坐标
    input  wire [10:0] ly,               // 局部行坐标
    input  wire [`OSD_TXT_W-1:0] txt,    // 13 字符，第 i 个在 txt[i*8+7 : i*8]
    output reg         draw,             // 坐标后 2 拍有效
    output reg  [1:0]  alpha,
    output reg  [2:0]  ink,
    input wire [7:0] glass_blue_src,output wire [7:0] glass_blue_rgb
);

    localparam integer CW = 6*SCALE;             // 字符格宽
    localparam integer CH = 8*SCALE;             // 字符格高
    localparam integer TXT_W = CW*CHARS;
    localparam integer TXT_H = CH;

    //-------------------------------------------------------------------------
    // A 拍（组合）：判界 + 字符列（13 路常数比较优先树，无除法）
    //-------------------------------------------------------------------------
    wire        inbox = (lx < TXT_W[10:0]) && (ly < TXT_H[10:0]);

    reg [10:0]  rem_x_a;                       // 格内列偏移 lx - col*CW
    reg [7:0]   ch_a;

    // 默认配置是 13 个字符、SCALE=2，即 CW=12。原先的 for 循环是
    // 13 级“最后一个命中者优先”链，在 TD 中没有自动平衡；下面用
    // 二分区间树同时完成字符选择和余数计算，最深只需 4 次比较。
    // 本 painter 本来就要求 SCALE 为 2 的幂；当前工程唯一实例固定为
    // SCALE=1/2, CHARS=13，复用同一平衡树及字库，并保留其他参数的回退。
    integer c;
    always @(*) begin
        rem_x_a = lx;
        ch_a = 8'h20;
        if (((SCALE == 1) || (SCALE == 2)) && (CHARS == 13)) begin
            if (lx < CW*6) begin
                if (lx < CW*3) begin
                    if (lx < CW*1) begin rem_x_a = lx;         ch_a = txt[7:0];   end
                    else if (lx < CW*2) begin rem_x_a = lx-CW*1; ch_a = txt[15:8];  end
                    else begin rem_x_a = lx-CW*2;                  ch_a = txt[23:16]; end
                end else begin
                    if (lx < CW*4) begin rem_x_a = lx-CW*3;      ch_a = txt[31:24]; end
                    else if (lx < CW*5) begin rem_x_a = lx-CW*4; ch_a = txt[39:32]; end
                    else begin rem_x_a = lx-CW*5;                  ch_a = txt[47:40]; end
                end
            end else if (lx < CW*10) begin
                if (lx < CW*8) begin
                    if (lx < CW*7) begin rem_x_a = lx-CW*6;      ch_a = txt[55:48]; end
                    else begin rem_x_a = lx-CW*7;                  ch_a = txt[63:56]; end
                end else begin
                    if (lx < CW*9) begin rem_x_a = lx-CW*8;     ch_a = txt[71:64]; end
                    else begin rem_x_a = lx-CW*9;                 ch_a = txt[79:72]; end
                end
            end else begin
                if (lx < CW*12) begin
                    if (lx < CW*11) begin rem_x_a = lx-CW*10;    ch_a = txt[87:80]; end
                    else begin rem_x_a = lx-CW*11;                 ch_a = txt[95:88]; end
                end else if (lx < CW*13) begin
                    rem_x_a = lx-CW*12; ch_a = txt[103:96];
                end
            end
        end else begin
            // 非工程默认参数的功能性回退路径。
            for (c = 0; c < CHARS; c = c + 1) begin
                if (lx >= CW*c) begin
                    rem_x_a = lx - CW*c;
                    ch_a = txt[c*8 +: 8];
                end
            end
        end
    end

    // A 拍寄存
    reg        inbox_a;
    reg [7:0]  ch_r;
    reg [10:0] gx_r, gy_r; // Native coordinates; SCALE=2 samples 1:1.

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            inbox_a <= 1'b0;
            ch_r    <= 8'h20;
            gx_r    <= 11'd0;
            gy_r    <= 11'd0;
        end else begin
            inbox_a <= inbox;
            ch_r    <= ch_a;
            gx_r    <= (rem_x_a*2)/SCALE;
            gy_r    <= (ly*2)/SCALE;
        end
    end

    // Native 10x14 coverage, no replicated source pixels. Keep painter latency
    // unchanged: coordinates/ASCII register, then row and coverage mux.
    `include "font_audio_rows.vh"
    wire [1:0] coverage;
    wire [10:0] glyph_x_a=(rem_x_a*2)/SCALE;
    wire [10:0] glyph_y_a=(ly*2)/SCALE;
    generate if(SCALE==1 || SCALE==2)begin: packed_audio_font
     function [3:0] glyph_index;input [6:0] code;begin
       glyph_index=(code>=47 && code<=58) ? code-7'd47:4'd12;
     end endfunction
     wire [7:0] glyph_word,shared_blue_word;
     resource_audio_compact9 u_font(.clk(clk),
       .a({glyph_index(ch_a[6:0]),glyph_y_a[3:0],glyph_x_a[3:2]}),
       .b({2'b11,(SHARED_GLASS ? glass_blue_src:8'd0)}),.qa(glyph_word),.qb(shared_blue_word));
     assign glass_blue_rgb=shared_blue_word;
     // Unsupported characters use zero coverage, independently of palette
     // reads in the unused glyph-index range. Full 8-bit ink choice is kept.
     assign coverage=(ch_r[6:0]>=47 && ch_r[6:0]<=58) ?
       glyph_word[{gx_r[1:0],1'b0} +:2]:2'd0;
    end else begin: generic_audio_font
     wire [7:0] blue_src=SHARED_GLASS ? glass_blue_src:8'd0;
     wire [9:0] blue_mix={2'd0,blue_src}+({2'd0,blue_src}>>1)+10'd13;
     assign glass_blue_rgb=blue_mix[9:2];
     wire [19:0] coverage_row=audio_font_row(ch_r[6:0],gy_r[4:0]);
     assign coverage=coverage_row[gx_r*2 +:2];
    end endgenerate
    always @(*) begin
        alpha=(inbox_a && gx_r<10 && gy_r<14) ? coverage:2'd0;
        draw=alpha!=0;
        ink=draw ? ((ch_r=="/") ? `OSD_INK_TEXTDIM:`OSD_INK_TEXT):3'd0;
    end
endmodule

module resource_audio_compact9(input wire clk,input wire [9:0] a,b,output wire [7:0] qa,qb);
`ifdef DB_BEHAVIORAL_RAM
reg [7:0] mem[0:1023],ra,rb;assign qa=ra;assign qb=rb;
initial begin
mem[0]=8'd0;
mem[1]=8'd192;
mem[2]=8'd1;
mem[3]=8'd0;
mem[4]=8'd0;
mem[5]=8'd224;
mem[6]=8'd0;
mem[7]=8'd0;
mem[8]=8'd0;
mem[9]=8'd176;
mem[10]=8'd0;
mem[11]=8'd0;
mem[12]=8'd0;
mem[13]=8'd52;
mem[14]=8'd0;
mem[15]=8'd0;
mem[16]=8'd0;
mem[17]=8'd44;
mem[18]=8'd0;
mem[19]=8'd0;
mem[20]=8'd0;
mem[21]=8'd29;
mem[22]=8'd0;
mem[23]=8'd0;
mem[24]=8'd0;
mem[25]=8'd11;
mem[26]=8'd0;
mem[27]=8'd0;
mem[28]=8'd64;
mem[29]=8'd7;
mem[30]=8'd0;
mem[31]=8'd0;
mem[32]=8'd128;
mem[33]=8'd2;
mem[34]=8'd0;
mem[35]=8'd0;
mem[36]=8'd208;
mem[37]=8'd1;
mem[38]=8'd0;
mem[39]=8'd0;
mem[40]=8'd224;
mem[41]=8'd0;
mem[42]=8'd0;
mem[43]=8'd0;
mem[44]=8'd116;
mem[45]=8'd0;
mem[46]=8'd0;
mem[47]=8'd0;
mem[48]=8'd20;
mem[49]=8'd0;
mem[50]=8'd0;
mem[51]=8'd0;
mem[52]=8'd0;
mem[53]=8'd0;
mem[54]=8'd0;
mem[55]=8'd0;
mem[56]=8'd0;
mem[57]=8'd0;
mem[58]=8'd0;
mem[59]=8'd0;
mem[60]=8'd0;
mem[61]=8'd0;
mem[62]=8'd0;
mem[63]=8'd0;
mem[64]=8'd128;
mem[65]=8'd47;
mem[66]=8'd0;
mem[67]=8'd0;
mem[68]=8'd224;
mem[69]=8'd191;
mem[70]=8'd0;
mem[71]=8'd0;
mem[72]=8'd244;
mem[73]=8'd240;
mem[74]=8'd1;
mem[75]=8'd0;
mem[76]=8'd180;
mem[77]=8'd224;
mem[78]=8'd1;
mem[79]=8'd0;
mem[80]=8'd184;
mem[81]=8'd229;
mem[82]=8'd2;
mem[83]=8'd0;
mem[84]=8'd184;
mem[85]=8'd239;
mem[86]=8'd2;
mem[87]=8'd0;
mem[88]=8'd184;
mem[89]=8'd229;
mem[90]=8'd2;
mem[91]=8'd0;
mem[92]=8'd180;
mem[93]=8'd224;
mem[94]=8'd1;
mem[95]=8'd0;
mem[96]=8'd244;
mem[97]=8'd240;
mem[98]=8'd1;
mem[99]=8'd0;
mem[100]=8'd240;
mem[101]=8'd250;
mem[102]=8'd0;
mem[103]=8'd0;
mem[104]=8'd208;
mem[105]=8'd127;
mem[106]=8'd0;
mem[107]=8'd0;
mem[108]=8'd0;
mem[109]=8'd5;
mem[110]=8'd0;
mem[111]=8'd0;
mem[112]=8'd0;
mem[113]=8'd0;
mem[114]=8'd0;
mem[115]=8'd0;
mem[116]=8'd0;
mem[117]=8'd0;
mem[118]=8'd0;
mem[119]=8'd0;
mem[120]=8'd0;
mem[121]=8'd0;
mem[122]=8'd0;
mem[123]=8'd0;
mem[124]=8'd0;
mem[125]=8'd0;
mem[126]=8'd0;
mem[127]=8'd0;
mem[128]=8'd144;
mem[129]=8'd31;
mem[130]=8'd0;
mem[131]=8'd0;
mem[132]=8'd240;
mem[133]=8'd31;
mem[134]=8'd0;
mem[135]=8'd0;
mem[136]=8'd80;
mem[137]=8'd30;
mem[138]=8'd0;
mem[139]=8'd0;
mem[140]=8'd0;
mem[141]=8'd30;
mem[142]=8'd0;
mem[143]=8'd0;
mem[144]=8'd0;
mem[145]=8'd30;
mem[146]=8'd0;
mem[147]=8'd0;
mem[148]=8'd0;
mem[149]=8'd30;
mem[150]=8'd0;
mem[151]=8'd0;
mem[152]=8'd0;
mem[153]=8'd30;
mem[154]=8'd0;
mem[155]=8'd0;
mem[156]=8'd0;
mem[157]=8'd30;
mem[158]=8'd0;
mem[159]=8'd0;
mem[160]=8'd0;
mem[161]=8'd30;
mem[162]=8'd0;
mem[163]=8'd0;
mem[164]=8'd240;
mem[165]=8'd255;
mem[166]=8'd2;
mem[167]=8'd0;
mem[168]=8'd240;
mem[169]=8'd255;
mem[170]=8'd2;
mem[171]=8'd0;
mem[172]=8'd0;
mem[173]=8'd0;
mem[174]=8'd0;
mem[175]=8'd0;
mem[176]=8'd0;
mem[177]=8'd0;
mem[178]=8'd0;
mem[179]=8'd0;
mem[180]=8'd0;
mem[181]=8'd0;
mem[182]=8'd0;
mem[183]=8'd0;
mem[184]=8'd0;
mem[185]=8'd0;
mem[186]=8'd0;
mem[187]=8'd0;
mem[188]=8'd0;
mem[189]=8'd0;
mem[190]=8'd0;
mem[191]=8'd0;
mem[192]=8'd228;
mem[193]=8'd111;
mem[194]=8'd0;
mem[195]=8'd0;
mem[196]=8'd180;
mem[197]=8'd254;
mem[198]=8'd0;
mem[199]=8'd0;
mem[200]=8'd0;
mem[201]=8'd240;
mem[202]=8'd1;
mem[203]=8'd0;
mem[204]=8'd0;
mem[205]=8'd240;
mem[206]=8'd1;
mem[207]=8'd0;
mem[208]=8'd0;
mem[209]=8'd244;
mem[210]=8'd0;
mem[211]=8'd0;
mem[212]=8'd0;
mem[213]=8'd125;
mem[214]=8'd0;
mem[215]=8'd0;
mem[216]=8'd64;
mem[217]=8'd31;
mem[218]=8'd0;
mem[219]=8'd0;
mem[220]=8'd192;
mem[221]=8'd7;
mem[222]=8'd0;
mem[223]=8'd0;
mem[224]=8'd240;
mem[225]=8'd1;
mem[226]=8'd0;
mem[227]=8'd0;
mem[228]=8'd248;
mem[229]=8'd255;
mem[230]=8'd1;
mem[231]=8'd0;
mem[232]=8'd248;
mem[233]=8'd255;
mem[234]=8'd1;
mem[235]=8'd0;
mem[236]=8'd0;
mem[237]=8'd0;
mem[238]=8'd0;
mem[239]=8'd0;
mem[240]=8'd0;
mem[241]=8'd0;
mem[242]=8'd0;
mem[243]=8'd0;
mem[244]=8'd0;
mem[245]=8'd0;
mem[246]=8'd0;
mem[247]=8'd0;
mem[248]=8'd0;
mem[249]=8'd0;
mem[250]=8'd0;
mem[251]=8'd0;
mem[252]=8'd0;
mem[253]=8'd0;
mem[254]=8'd0;
mem[255]=8'd0;
mem[256]=8'd228;
mem[257]=8'd111;
mem[258]=8'd0;
mem[259]=8'd0;
mem[260]=8'd244;
mem[261]=8'd254;
mem[262]=8'd0;
mem[263]=8'd0;
mem[264]=8'd0;
mem[265]=8'd240;
mem[266]=8'd1;
mem[267]=8'd0;
mem[268]=8'd0;
mem[269]=8'd240;
mem[270]=8'd1;
mem[271]=8'd0;
mem[272]=8'd64;
mem[273]=8'd190;
mem[274]=8'd0;
mem[275]=8'd0;
mem[276]=8'd128;
mem[277]=8'd111;
mem[278]=8'd0;
mem[279]=8'd0;
mem[280]=8'd0;
mem[281]=8'd244;
mem[282]=8'd1;
mem[283]=8'd0;
mem[284]=8'd0;
mem[285]=8'd224;
mem[286]=8'd2;
mem[287]=8'd0;
mem[288]=8'd0;
mem[289]=8'd224;
mem[290]=8'd2;
mem[291]=8'd0;
mem[292]=8'd184;
mem[293]=8'd250;
mem[294]=8'd1;
mem[295]=8'd0;
mem[296]=8'd244;
mem[297]=8'd127;
mem[298]=8'd0;
mem[299]=8'd0;
mem[300]=8'd64;
mem[301]=8'd5;
mem[302]=8'd0;
mem[303]=8'd0;
mem[304]=8'd0;
mem[305]=8'd0;
mem[306]=8'd0;
mem[307]=8'd0;
mem[308]=8'd0;
mem[309]=8'd0;
mem[310]=8'd0;
mem[311]=8'd0;
mem[312]=8'd0;
mem[313]=8'd0;
mem[314]=8'd0;
mem[315]=8'd0;
mem[316]=8'd0;
mem[317]=8'd0;
mem[318]=8'd0;
mem[319]=8'd0;
mem[320]=8'd0;
mem[321]=8'd184;
mem[322]=8'd0;
mem[323]=8'd0;
mem[324]=8'd0;
mem[325]=8'd189;
mem[326]=8'd0;
mem[327]=8'd0;
mem[328]=8'd0;
mem[329]=8'd191;
mem[330]=8'd0;
mem[331]=8'd0;
mem[332]=8'd128;
mem[333]=8'd183;
mem[334]=8'd0;
mem[335]=8'd0;
mem[336]=8'd208;
mem[337]=8'd181;
mem[338]=8'd0;
mem[339]=8'd0;
mem[340]=8'd176;
mem[341]=8'd180;
mem[342]=8'd0;
mem[343]=8'd0;
mem[344]=8'd120;
mem[345]=8'd185;
mem[346]=8'd1;
mem[347]=8'd0;
mem[348]=8'd248;
mem[349]=8'd255;
mem[350]=8'd3;
mem[351]=8'd0;
mem[352]=8'd164;
mem[353]=8'd250;
mem[354]=8'd2;
mem[355]=8'd0;
mem[356]=8'd0;
mem[357]=8'd180;
mem[358]=8'd0;
mem[359]=8'd0;
mem[360]=8'd0;
mem[361]=8'd180;
mem[362]=8'd0;
mem[363]=8'd0;
mem[364]=8'd0;
mem[365]=8'd0;
mem[366]=8'd0;
mem[367]=8'd0;
mem[368]=8'd0;
mem[369]=8'd0;
mem[370]=8'd0;
mem[371]=8'd0;
mem[372]=8'd0;
mem[373]=8'd0;
mem[374]=8'd0;
mem[375]=8'd0;
mem[376]=8'd0;
mem[377]=8'd0;
mem[378]=8'd0;
mem[379]=8'd0;
mem[380]=8'd0;
mem[381]=8'd0;
mem[382]=8'd0;
mem[383]=8'd0;
mem[384]=8'd240;
mem[385]=8'd191;
mem[386]=8'd0;
mem[387]=8'd0;
mem[388]=8'd240;
mem[389]=8'd255;
mem[390]=8'd0;
mem[391]=8'd0;
mem[392]=8'd176;
mem[393]=8'd0;
mem[394]=8'd0;
mem[395]=8'd0;
mem[396]=8'd176;
mem[397]=8'd5;
mem[398]=8'd0;
mem[399]=8'd0;
mem[400]=8'd240;
mem[401]=8'd127;
mem[402]=8'd0;
mem[403]=8'd0;
mem[404]=8'd176;
mem[405]=8'd250;
mem[406]=8'd0;
mem[407]=8'd0;
mem[408]=8'd0;
mem[409]=8'd224;
mem[410]=8'd1;
mem[411]=8'd0;
mem[412]=8'd0;
mem[413]=8'd224;
mem[414]=8'd2;
mem[415]=8'd0;
mem[416]=8'd0;
mem[417]=8'd240;
mem[418]=8'd1;
mem[419]=8'd0;
mem[420]=8'd180;
mem[421]=8'd254;
mem[422]=8'd0;
mem[423]=8'd0;
mem[424]=8'd244;
mem[425]=8'd111;
mem[426]=8'd0;
mem[427]=8'd0;
mem[428]=8'd64;
mem[429]=8'd1;
mem[430]=8'd0;
mem[431]=8'd0;
mem[432]=8'd0;
mem[433]=8'd0;
mem[434]=8'd0;
mem[435]=8'd0;
mem[436]=8'd0;
mem[437]=8'd0;
mem[438]=8'd0;
mem[439]=8'd0;
mem[440]=8'd0;
mem[441]=8'd0;
mem[442]=8'd0;
mem[443]=8'd0;
mem[444]=8'd0;
mem[445]=8'd0;
mem[446]=8'd0;
mem[447]=8'd0;
mem[448]=8'd128;
mem[449]=8'd191;
mem[450]=8'd0;
mem[451]=8'd0;
mem[452]=8'd224;
mem[453]=8'd235;
mem[454]=8'd0;
mem[455]=8'd0;
mem[456]=8'd240;
mem[457]=8'd0;
mem[458]=8'd0;
mem[459]=8'd0;
mem[460]=8'd180;
mem[461]=8'd4;
mem[462]=8'd0;
mem[463]=8'd0;
mem[464]=8'd180;
mem[465]=8'd191;
mem[466]=8'd0;
mem[467]=8'd0;
mem[468]=8'd248;
mem[469]=8'd250;
mem[470]=8'd1;
mem[471]=8'd0;
mem[472]=8'd248;
mem[473]=8'd208;
mem[474]=8'd2;
mem[475]=8'd0;
mem[476]=8'd180;
mem[477]=8'd208;
mem[478]=8'd2;
mem[479]=8'd0;
mem[480]=8'd244;
mem[481]=8'd208;
mem[482]=8'd2;
mem[483]=8'd0;
mem[484]=8'd240;
mem[485]=8'd250;
mem[486]=8'd1;
mem[487]=8'd0;
mem[488]=8'd208;
mem[489]=8'd191;
mem[490]=8'd0;
mem[491]=8'd0;
mem[492]=8'd0;
mem[493]=8'd5;
mem[494]=8'd0;
mem[495]=8'd0;
mem[496]=8'd0;
mem[497]=8'd0;
mem[498]=8'd0;
mem[499]=8'd0;
mem[500]=8'd0;
mem[501]=8'd0;
mem[502]=8'd0;
mem[503]=8'd0;
mem[504]=8'd0;
mem[505]=8'd0;
mem[506]=8'd0;
mem[507]=8'd0;
mem[508]=8'd0;
mem[509]=8'd0;
mem[510]=8'd0;
mem[511]=8'd0;
mem[512]=8'd244;
mem[513]=8'd255;
mem[514]=8'd1;
mem[515]=8'd0;
mem[516]=8'd248;
mem[517]=8'd255;
mem[518]=8'd1;
mem[519]=8'd0;
mem[520]=8'd0;
mem[521]=8'd240;
mem[522]=8'd0;
mem[523]=8'd0;
mem[524]=8'd0;
mem[525]=8'd184;
mem[526]=8'd0;
mem[527]=8'd0;
mem[528]=8'd0;
mem[529]=8'd124;
mem[530]=8'd0;
mem[531]=8'd0;
mem[532]=8'd0;
mem[533]=8'd61;
mem[534]=8'd0;
mem[535]=8'd0;
mem[536]=8'd0;
mem[537]=8'd30;
mem[538]=8'd0;
mem[539]=8'd0;
mem[540]=8'd0;
mem[541]=8'd15;
mem[542]=8'd0;
mem[543]=8'd0;
mem[544]=8'd128;
mem[545]=8'd11;
mem[546]=8'd0;
mem[547]=8'd0;
mem[548]=8'd192;
mem[549]=8'd7;
mem[550]=8'd0;
mem[551]=8'd0;
mem[552]=8'd208;
mem[553]=8'd3;
mem[554]=8'd0;
mem[555]=8'd0;
mem[556]=8'd0;
mem[557]=8'd0;
mem[558]=8'd0;
mem[559]=8'd0;
mem[560]=8'd0;
mem[561]=8'd0;
mem[562]=8'd0;
mem[563]=8'd0;
mem[564]=8'd0;
mem[565]=8'd0;
mem[566]=8'd0;
mem[567]=8'd0;
mem[568]=8'd0;
mem[569]=8'd0;
mem[570]=8'd0;
mem[571]=8'd0;
mem[572]=8'd0;
mem[573]=8'd0;
mem[574]=8'd0;
mem[575]=8'd0;
mem[576]=8'd208;
mem[577]=8'd127;
mem[578]=8'd0;
mem[579]=8'd0;
mem[580]=8'd240;
mem[581]=8'd250;
mem[582]=8'd0;
mem[583]=8'd0;
mem[584]=8'd180;
mem[585]=8'd224;
mem[586]=8'd1;
mem[587]=8'd0;
mem[588]=8'd180;
mem[589]=8'd224;
mem[590]=8'd1;
mem[591]=8'd0;
mem[592]=8'd224;
mem[593]=8'd186;
mem[594]=8'd0;
mem[595]=8'd0;
mem[596]=8'd208;
mem[597]=8'd127;
mem[598]=8'd0;
mem[599]=8'd0;
mem[600]=8'd244;
mem[601]=8'd245;
mem[602]=8'd1;
mem[603]=8'd0;
mem[604]=8'd120;
mem[605]=8'd208;
mem[606]=8'd2;
mem[607]=8'd0;
mem[608]=8'd184;
mem[609]=8'd224;
mem[610]=8'd2;
mem[611]=8'd0;
mem[612]=8'd244;
mem[613]=8'd250;
mem[614]=8'd1;
mem[615]=8'd0;
mem[616]=8'd208;
mem[617]=8'd127;
mem[618]=8'd0;
mem[619]=8'd0;
mem[620]=8'd0;
mem[621]=8'd5;
mem[622]=8'd0;
mem[623]=8'd0;
mem[624]=8'd0;
mem[625]=8'd0;
mem[626]=8'd0;
mem[627]=8'd0;
mem[628]=8'd0;
mem[629]=8'd0;
mem[630]=8'd0;
mem[631]=8'd0;
mem[632]=8'd0;
mem[633]=8'd0;
mem[634]=8'd0;
mem[635]=8'd0;
mem[636]=8'd0;
mem[637]=8'd0;
mem[638]=8'd0;
mem[639]=8'd0;
mem[640]=8'd208;
mem[641]=8'd47;
mem[642]=8'd0;
mem[643]=8'd0;
mem[644]=8'd244;
mem[645]=8'd186;
mem[646]=8'd0;
mem[647]=8'd0;
mem[648]=8'd184;
mem[649]=8'd240;
mem[650]=8'd1;
mem[651]=8'd0;
mem[652]=8'd120;
mem[653]=8'd224;
mem[654]=8'd1;
mem[655]=8'd0;
mem[656]=8'd184;
mem[657]=8'd240;
mem[658]=8'd2;
mem[659]=8'd0;
mem[660]=8'd244;
mem[661]=8'd250;
mem[662]=8'd2;
mem[663]=8'd0;
mem[664]=8'd224;
mem[665]=8'd239;
mem[666]=8'd2;
mem[667]=8'd0;
mem[668]=8'd0;
mem[669]=8'd225;
mem[670]=8'd1;
mem[671]=8'd0;
mem[672]=8'd0;
mem[673]=8'd240;
mem[674]=8'd0;
mem[675]=8'd0;
mem[676]=8'd176;
mem[677]=8'd190;
mem[678]=8'd0;
mem[679]=8'd0;
mem[680]=8'd240;
mem[681]=8'd47;
mem[682]=8'd0;
mem[683]=8'd0;
mem[684]=8'd64;
mem[685]=8'd1;
mem[686]=8'd0;
mem[687]=8'd0;
mem[688]=8'd0;
mem[689]=8'd0;
mem[690]=8'd0;
mem[691]=8'd0;
mem[692]=8'd0;
mem[693]=8'd0;
mem[694]=8'd0;
mem[695]=8'd0;
mem[696]=8'd0;
mem[697]=8'd0;
mem[698]=8'd0;
mem[699]=8'd0;
mem[700]=8'd0;
mem[701]=8'd0;
mem[702]=8'd0;
mem[703]=8'd0;
mem[704]=8'd0;
mem[705]=8'd0;
mem[706]=8'd0;
mem[707]=8'd0;
mem[708]=8'd0;
mem[709]=8'd0;
mem[710]=8'd0;
mem[711]=8'd0;
mem[712]=8'd0;
mem[713]=8'd0;
mem[714]=8'd0;
mem[715]=8'd0;
mem[716]=8'd0;
mem[717]=8'd26;
mem[718]=8'd0;
mem[719]=8'd0;
mem[720]=8'd64;
mem[721]=8'd31;
mem[722]=8'd0;
mem[723]=8'd0;
mem[724]=8'd64;
mem[725]=8'd31;
mem[726]=8'd0;
mem[727]=8'd0;
mem[728]=8'd0;
mem[729]=8'd0;
mem[730]=8'd0;
mem[731]=8'd0;
mem[732]=8'd0;
mem[733]=8'd0;
mem[734]=8'd0;
mem[735]=8'd0;
mem[736]=8'd0;
mem[737]=8'd26;
mem[738]=8'd0;
mem[739]=8'd0;
mem[740]=8'd64;
mem[741]=8'd31;
mem[742]=8'd0;
mem[743]=8'd0;
mem[744]=8'd64;
mem[745]=8'd31;
mem[746]=8'd0;
mem[747]=8'd0;
mem[748]=8'd0;
mem[749]=8'd0;
mem[750]=8'd0;
mem[751]=8'd0;
mem[752]=8'd0;
mem[753]=8'd0;
mem[754]=8'd0;
mem[755]=8'd0;
mem[756]=8'd0;
mem[757]=8'd0;
mem[758]=8'd0;
mem[759]=8'd0;
mem[760]=8'd0;
mem[761]=8'd0;
mem[762]=8'd0;
mem[763]=8'd0;
mem[764]=8'd0;
mem[765]=8'd0;
mem[766]=8'd0;
mem[767]=8'd0;
mem[768]=8'd3;
mem[769]=8'd3;
mem[770]=8'd4;
mem[771]=8'd4;
mem[772]=8'd4;
mem[773]=8'd5;
mem[774]=8'd5;
mem[775]=8'd5;
mem[776]=8'd6;
mem[777]=8'd6;
mem[778]=8'd7;
mem[779]=8'd7;
mem[780]=8'd7;
mem[781]=8'd8;
mem[782]=8'd8;
mem[783]=8'd8;
mem[784]=8'd9;
mem[785]=8'd9;
mem[786]=8'd10;
mem[787]=8'd10;
mem[788]=8'd10;
mem[789]=8'd11;
mem[790]=8'd11;
mem[791]=8'd11;
mem[792]=8'd12;
mem[793]=8'd12;
mem[794]=8'd13;
mem[795]=8'd13;
mem[796]=8'd13;
mem[797]=8'd14;
mem[798]=8'd14;
mem[799]=8'd14;
mem[800]=8'd15;
mem[801]=8'd15;
mem[802]=8'd16;
mem[803]=8'd16;
mem[804]=8'd16;
mem[805]=8'd17;
mem[806]=8'd17;
mem[807]=8'd17;
mem[808]=8'd18;
mem[809]=8'd18;
mem[810]=8'd19;
mem[811]=8'd19;
mem[812]=8'd19;
mem[813]=8'd20;
mem[814]=8'd20;
mem[815]=8'd20;
mem[816]=8'd21;
mem[817]=8'd21;
mem[818]=8'd22;
mem[819]=8'd22;
mem[820]=8'd22;
mem[821]=8'd23;
mem[822]=8'd23;
mem[823]=8'd23;
mem[824]=8'd24;
mem[825]=8'd24;
mem[826]=8'd25;
mem[827]=8'd25;
mem[828]=8'd25;
mem[829]=8'd26;
mem[830]=8'd26;
mem[831]=8'd26;
mem[832]=8'd27;
mem[833]=8'd27;
mem[834]=8'd28;
mem[835]=8'd28;
mem[836]=8'd28;
mem[837]=8'd29;
mem[838]=8'd29;
mem[839]=8'd29;
mem[840]=8'd30;
mem[841]=8'd30;
mem[842]=8'd31;
mem[843]=8'd31;
mem[844]=8'd31;
mem[845]=8'd32;
mem[846]=8'd32;
mem[847]=8'd32;
mem[848]=8'd33;
mem[849]=8'd33;
mem[850]=8'd34;
mem[851]=8'd34;
mem[852]=8'd34;
mem[853]=8'd35;
mem[854]=8'd35;
mem[855]=8'd35;
mem[856]=8'd36;
mem[857]=8'd36;
mem[858]=8'd37;
mem[859]=8'd37;
mem[860]=8'd37;
mem[861]=8'd38;
mem[862]=8'd38;
mem[863]=8'd38;
mem[864]=8'd39;
mem[865]=8'd39;
mem[866]=8'd40;
mem[867]=8'd40;
mem[868]=8'd40;
mem[869]=8'd41;
mem[870]=8'd41;
mem[871]=8'd41;
mem[872]=8'd42;
mem[873]=8'd42;
mem[874]=8'd43;
mem[875]=8'd43;
mem[876]=8'd43;
mem[877]=8'd44;
mem[878]=8'd44;
mem[879]=8'd44;
mem[880]=8'd45;
mem[881]=8'd45;
mem[882]=8'd46;
mem[883]=8'd46;
mem[884]=8'd46;
mem[885]=8'd47;
mem[886]=8'd47;
mem[887]=8'd47;
mem[888]=8'd48;
mem[889]=8'd48;
mem[890]=8'd49;
mem[891]=8'd49;
mem[892]=8'd49;
mem[893]=8'd50;
mem[894]=8'd50;
mem[895]=8'd50;
mem[896]=8'd51;
mem[897]=8'd51;
mem[898]=8'd52;
mem[899]=8'd52;
mem[900]=8'd52;
mem[901]=8'd53;
mem[902]=8'd53;
mem[903]=8'd53;
mem[904]=8'd54;
mem[905]=8'd54;
mem[906]=8'd55;
mem[907]=8'd55;
mem[908]=8'd55;
mem[909]=8'd56;
mem[910]=8'd56;
mem[911]=8'd56;
mem[912]=8'd57;
mem[913]=8'd57;
mem[914]=8'd58;
mem[915]=8'd58;
mem[916]=8'd58;
mem[917]=8'd59;
mem[918]=8'd59;
mem[919]=8'd59;
mem[920]=8'd60;
mem[921]=8'd60;
mem[922]=8'd61;
mem[923]=8'd61;
mem[924]=8'd61;
mem[925]=8'd62;
mem[926]=8'd62;
mem[927]=8'd62;
mem[928]=8'd63;
mem[929]=8'd63;
mem[930]=8'd64;
mem[931]=8'd64;
mem[932]=8'd64;
mem[933]=8'd65;
mem[934]=8'd65;
mem[935]=8'd65;
mem[936]=8'd66;
mem[937]=8'd66;
mem[938]=8'd67;
mem[939]=8'd67;
mem[940]=8'd67;
mem[941]=8'd68;
mem[942]=8'd68;
mem[943]=8'd68;
mem[944]=8'd69;
mem[945]=8'd69;
mem[946]=8'd70;
mem[947]=8'd70;
mem[948]=8'd70;
mem[949]=8'd71;
mem[950]=8'd71;
mem[951]=8'd71;
mem[952]=8'd72;
mem[953]=8'd72;
mem[954]=8'd73;
mem[955]=8'd73;
mem[956]=8'd73;
mem[957]=8'd74;
mem[958]=8'd74;
mem[959]=8'd74;
mem[960]=8'd75;
mem[961]=8'd75;
mem[962]=8'd76;
mem[963]=8'd76;
mem[964]=8'd76;
mem[965]=8'd77;
mem[966]=8'd77;
mem[967]=8'd77;
mem[968]=8'd78;
mem[969]=8'd78;
mem[970]=8'd79;
mem[971]=8'd79;
mem[972]=8'd79;
mem[973]=8'd80;
mem[974]=8'd80;
mem[975]=8'd80;
mem[976]=8'd81;
mem[977]=8'd81;
mem[978]=8'd82;
mem[979]=8'd82;
mem[980]=8'd82;
mem[981]=8'd83;
mem[982]=8'd83;
mem[983]=8'd83;
mem[984]=8'd84;
mem[985]=8'd84;
mem[986]=8'd85;
mem[987]=8'd85;
mem[988]=8'd85;
mem[989]=8'd86;
mem[990]=8'd86;
mem[991]=8'd86;
mem[992]=8'd87;
mem[993]=8'd87;
mem[994]=8'd88;
mem[995]=8'd88;
mem[996]=8'd88;
mem[997]=8'd89;
mem[998]=8'd89;
mem[999]=8'd89;
mem[1000]=8'd90;
mem[1001]=8'd90;
mem[1002]=8'd91;
mem[1003]=8'd91;
mem[1004]=8'd91;
mem[1005]=8'd92;
mem[1006]=8'd92;
mem[1007]=8'd92;
mem[1008]=8'd93;
mem[1009]=8'd93;
mem[1010]=8'd94;
mem[1011]=8'd94;
mem[1012]=8'd94;
mem[1013]=8'd95;
mem[1014]=8'd95;
mem[1015]=8'd95;
mem[1016]=8'd96;
mem[1017]=8'd96;
mem[1018]=8'd97;
mem[1019]=8'd97;
mem[1020]=8'd97;
mem[1021]=8'd98;
mem[1022]=8'd98;
mem[1023]=8'd98;
end
always @(posedge clk)begin ra<=mem[a];rb<=mem[b];end
`else
wire [8:0] ra,rb;assign qa=ra[7:0];assign qb=rb[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.GSR("DISABLE"),
.INIT_00(256'h0000074000000b0000001d0000002c00000034000000b0000000e0000001c000),
.INIT_01(256'h0000000000000000000000000000001400000074000000e0000001d000000280),
.INIT_02(256'h0001e0b40002e5b80002efb80002e5b80001e0b40001f0f40000bfe000002f80),
.INIT_03(256'h000000000000000000000000000000000000050000007fd00000faf00001f0f4),
.INIT_04(256'h00001e0000001e0000001e0000001e0000001e0000001e5000001ff000001f90),
.INIT_05(256'h00000000000000000000000000000000000000000002fff00002fff000001e00),
.INIT_06(256'h000007c000001f4000007d000000f4000001f0000001f0000000feb400006fe4),
.INIT_07(256'h00000000000000000000000000000000000000000001fff80001fff8000001f0),
.INIT_08(256'h0002e0000001f40000006f800000be400001f0000001f0000000fef400006fe4),
.INIT_09(256'h000000000000000000000000000000000000054000007ff40001fab80002e000),
.INIT_0A(256'h0003fff80001b9780000b4b00000b5d00000b7800000bf000000bd000000b800),
.INIT_0B(256'h00000000000000000000000000000000000000000000b4000000b4000002faa4),
.INIT_0C(256'h0002e0000001e0000000fab000007ff0000005b0000000b00000fff00000bff0),
.INIT_0D(256'h000000000000000000000000000000000000014000006ff40000feb40001f000),
.INIT_0E(256'h0002d0b40002d0f80001faf80000bfb4000004b4000000f00000ebe00000bf80),
.INIT_0F(256'h00000000000000000000000000000000000005000000bfd00001faf00002d0f4),
.INIT_10(256'h00000f0000001e0000003d0000007c000000b8000000f0000001fff80001fff4),
.INIT_11(256'h0000000000000000000000000000000000000000000003d0000007c000000b80),
.INIT_12(256'h0002d0780001f5f400007fd00000bae00001e0b40001e0b40000faf000007fd0),
.INIT_13(256'h000000000000000000000000000000000000050000007fd00001faf40002e0b8),
.INIT_14(256'h0001e1000002efe00002faf40002f0b80001e0780001f0b80000baf400002fd0),
.INIT_15(256'h000000000000000000000000000000000000014000002ff00000beb00000f000),
.INIT_16(256'h000000000000000000001f4000001f4000001a00000000000000000000000000),
.INIT_17(256'h000000000000000000000000000000000000000000001f4000001f4000001a00),
.INIT_18(256'h0e0e0e0d0d0d0c0c0b0b0b0a0a0a090908080807070706060505050404040303),
.INIT_19(256'h1a1a1a1919191818171717161616151514141413131312121111111010100f0f),
.INIT_1A(256'h262626252525242423232322222221212020201f1f1f1e1e1d1d1d1c1c1c1b1b),
.INIT_1B(256'h32323231313130302f2f2f2e2e2e2d2d2c2c2c2b2b2b2a2a2929292828282727),
.INIT_1C(256'h3e3e3e3d3d3d3c3c3b3b3b3a3a3a393938383837373736363535353434343333),
.INIT_1D(256'h4a4a4a4949494848474747464646454544444443434342424141414040403f3f),
.INIT_1E(256'h565656555555545453535352525251515050504f4f4f4e4e4d4d4d4c4c4c4b4b),
.INIT_1F(256'h62626261616160605f5f5f5e5e5e5d5d5c5c5c5b5b5b5a5a5959595858585757)) u_rom(
.clka(clk),.cea(1'b1),.ocea(1'b1),.rsta(1'b0),.wea(1'b0),.csa(3'b111),.addra({a,3'b000}),.dia(9'd0),.doa(ra),
.clkb(clk),.ceb(1'b1),.oceb(1'b1),.rstb(1'b0),.web(1'b0),.csb(3'b111),.addrb({b,3'b000}),.dib(9'd0),.dob(rb));
`endif
endmodule
