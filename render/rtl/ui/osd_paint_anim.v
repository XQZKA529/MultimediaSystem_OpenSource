// 80 narrow glass bars interpolated from the existing 12 Goertzel bands.
// REGISTERED splits selection from interpolation/geometry. The parent uses
// its existing second decision stage, retaining two-clock OSD latency.
`include "../pkg/osd_model_bus.vh"
module osd_paint_anim #(
    parameter integer REGISTERED = 0,
    parameter integer NBANDS = 12,
    parameter integer BAND_W = 4,       // Kept for source compatibility.
    parameter integer BAND_SH= 2,
    parameter integer ANIM_W = 1280,
    parameter integer ANIM_H = 88
)(
    input wire clk,rst,
    input  wire [10:0]          lx,
    input  wire [10:0]          ly,
    input  wire [NBANDS*5-1:0]  heights,
    input  wire                 paused,
    output reg                  draw,
    output reg  [2:0]           ink
);
    localparam integer NBARS = 80;
    localparam integer CELL_SHIFT = 4;   // 16 px pitch
    localparam integer BAR_INSET = 2;
    localparam integer BAR_WIDTH = 12;
    localparam [4:0] MAX_HEIGHT = ANIM_H >> 2; // Existing 5-bit level ×4 = 88 px.

    // Static 12-band interpolation map: 80 display positions sample the
    // original frequency axis evenly. Two fractional bits limit the mapper
    // to a small constant table; the analyser and its 60-bit payload stay put.
    function [5:0] band_map;
        input [6:0] column;
        begin
            case (column)
                7'd0: band_map = {4'd0, 2'd0};
                7'd1: band_map = {4'd0, 2'd1};
                7'd2: band_map = {4'd0, 2'd1};
                7'd3: band_map = {4'd0, 2'd2};
                7'd4: band_map = {4'd0, 2'd2};
                7'd5: band_map = {4'd0, 2'd3};
                7'd6: band_map = {4'd0, 2'd3};
                7'd7: band_map = {4'd1, 2'd0};
                7'd8: band_map = {4'd1, 2'd0};
                7'd9: band_map = {4'd1, 2'd1};
                7'd10: band_map = {4'd1, 2'd2};
                7'd11: band_map = {4'd1, 2'd2};
                7'd12: band_map = {4'd1, 2'd3};
                7'd13: band_map = {4'd1, 2'd3};
                7'd14: band_map = {4'd2, 2'd0};
                7'd15: band_map = {4'd2, 2'd0};
                7'd16: band_map = {4'd2, 2'd1};
                7'd17: band_map = {4'd2, 2'd1};
                7'd18: band_map = {4'd2, 2'd2};
                7'd19: band_map = {4'd2, 2'd3};
                7'd20: band_map = {4'd2, 2'd3};
                7'd21: band_map = {4'd3, 2'd0};
                7'd22: band_map = {4'd3, 2'd0};
                7'd23: band_map = {4'd3, 2'd1};
                7'd24: band_map = {4'd3, 2'd1};
                7'd25: band_map = {4'd3, 2'd2};
                7'd26: band_map = {4'd3, 2'd2};
                7'd27: band_map = {4'd3, 2'd3};
                7'd28: band_map = {4'd4, 2'd0};
                7'd29: band_map = {4'd4, 2'd0};
                7'd30: band_map = {4'd4, 2'd1};
                7'd31: band_map = {4'd4, 2'd1};
                7'd32: band_map = {4'd4, 2'd2};
                7'd33: band_map = {4'd4, 2'd2};
                7'd34: band_map = {4'd4, 2'd3};
                7'd35: band_map = {4'd4, 2'd3};
                7'd36: band_map = {4'd5, 2'd0};
                7'd37: band_map = {4'd5, 2'd1};
                7'd38: band_map = {4'd5, 2'd1};
                7'd39: band_map = {4'd5, 2'd2};
                7'd40: band_map = {4'd5, 2'd2};
                7'd41: band_map = {4'd5, 2'd3};
                7'd42: band_map = {4'd5, 2'd3};
                7'd43: band_map = {4'd6, 2'd0};
                7'd44: band_map = {4'd6, 2'd1};
                7'd45: band_map = {4'd6, 2'd1};
                7'd46: band_map = {4'd6, 2'd2};
                7'd47: band_map = {4'd6, 2'd2};
                7'd48: band_map = {4'd6, 2'd3};
                7'd49: band_map = {4'd6, 2'd3};
                7'd50: band_map = {4'd7, 2'd0};
                7'd51: band_map = {4'd7, 2'd0};
                7'd52: band_map = {4'd7, 2'd1};
                7'd53: band_map = {4'd7, 2'd2};
                7'd54: band_map = {4'd7, 2'd2};
                7'd55: band_map = {4'd7, 2'd3};
                7'd56: band_map = {4'd7, 2'd3};
                7'd57: band_map = {4'd8, 2'd0};
                7'd58: band_map = {4'd8, 2'd0};
                7'd59: band_map = {4'd8, 2'd1};
                7'd60: band_map = {4'd8, 2'd1};
                7'd61: band_map = {4'd8, 2'd2};
                7'd62: band_map = {4'd8, 2'd3};
                7'd63: band_map = {4'd8, 2'd3};
                7'd64: band_map = {4'd9, 2'd0};
                7'd65: band_map = {4'd9, 2'd0};
                7'd66: band_map = {4'd9, 2'd1};
                7'd67: band_map = {4'd9, 2'd1};
                7'd68: band_map = {4'd9, 2'd2};
                7'd69: band_map = {4'd9, 2'd2};
                7'd70: band_map = {4'd9, 2'd3};
                7'd71: band_map = {4'd10, 2'd0};
                7'd72: band_map = {4'd10, 2'd0};
                7'd73: band_map = {4'd10, 2'd1};
                7'd74: band_map = {4'd10, 2'd1};
                7'd75: band_map = {4'd10, 2'd2};
                7'd76: band_map = {4'd10, 2'd2};
                7'd77: band_map = {4'd10, 2'd3};
                7'd78: band_map = {4'd10, 2'd3};
                7'd79: band_map = {4'd11, 2'd0};
                default: band_map = 6'd0;
            endcase
        end
    endfunction

    wire [6:0] column = lx[CELL_SHIFT+6:CELL_SHIFT];
    wire [3:0] cell_x = lx[CELL_SHIFT-1:0];
    wire [5:0] mapping = band_map(column);
    wire [3:0] band = mapping[5:2];
    wire [1:0] fraction = mapping[1:0];
    // Clamp each source before selection. Both neighbours share the same
    // selector; no variable band+1 arithmetic lies on the pixel coordinate path.
    wire [NBANDS*5-1:0] clamped;
    genvar bi;
    generate for(bi=0;bi<NBANDS;bi=bi+1) begin:clamp_band
        assign clamped[bi*5 +: 5]=heights[bi*5 +: 5]>MAX_HEIGHT ?
            MAX_HEIGHT:heights[bi*5 +: 5];
    end endgenerate
    wire [NBANDS*5-1:0] neighbours={clamped[NBANDS*5-1 -: 5],clamped[NBANDS*5-1:5]};
    wire [4:0] h0_raw=clamped[band*5 +: 5];
    wire [4:0] h1_raw=neighbours[band*5 +: 5];
    wire [4:0] h0,h1;
    wire [1:0] frac;
    wire [3:0] cx;
    wire [6:0] py;
    wire bounds_ok,paused_q;
    generate if(REGISTERED) begin:selection_stage
        reg [4:0] a,b;
        reg [1:0] f;
        reg [3:0] x;
        reg [6:0] y;
        reg inside,hold_pause;
        always @(posedge clk or posedge rst) begin
            if(rst) begin a<=0;b<=0;f<=0;x<=0;y<=0;inside<=0;hold_pause<=0;end
            else begin
                a<=h0_raw;b<=h1_raw;f<=fraction;x<=cell_x;y<=ly[6:0];
                inside<=lx<ANIM_W && ly<ANIM_H && column<NBARS;
                hold_pause<=paused;
            end
        end
        assign h0=a;assign h1=b;assign frac=f;assign cx=x;assign py=y;
        assign bounds_ok=inside;assign paused_q=hold_pause;
    end else begin:combinational_probe
        assign h0=h0_raw;assign h1=h1_raw;assign frac=fraction;assign cx=cell_x;assign py=ly[6:0];
        assign bounds_ok=lx<ANIM_W && ly<ANIM_H && column<NBARS;
        assign paused_q=paused;
    end endgenerate
    // Parallel weighted sums preserve the original rounding away from h0 at
    // half steps. Remove compare/subtract/multiply/round/add in series.
    wire [6:0] weight1=({2'd0,h0}<<1)+{2'd0,h0}+{2'd0,h1};
    wire [6:0] weight3={2'd0,h0}+({2'd0,h1}<<1)+{2'd0,h1};
    wire [6:0] bias=h1>=h0 ? 7'd2:7'd1;
    wire [6:0] quarter1=weight1+bias,quarter3=weight3+bias;
    wire [5:0] half_sum={1'b0,h0}+{1'b0,h1}+(h1>=h0 ? 6'd1:6'd0);
    wire [4:0] h=frac==0 ? h0:frac==1 ? quarter1[6:2]:frac==2 ? half_sum[5:1]:quarter3[6:2];
    // top_y is always a multiple of 4, so the cap's row offset is just py[1:0]
    // and the whole 4-row cap lives in the single row band py[6:2]==MAX_HEIGHT-h.
    // Semicircle of radius BAR_WIDTH/2: insets 4,2,1,1 (widths 4,8,10,10).
    wire [4:0] top_row=MAX_HEIGHT-h;
    wire [4:0] py_row=py[6:2];
    wire [1:0] cap_d=py[1:0];
    wire cap_row=py_row==top_row;
    wire [3:0] cap_inset=cap_d[1] ? 4'd1 : cap_d[0] ? 4'd2 : 4'd4;
    wire [3:0] cap_lo=BAR_INSET+cap_inset;
    wire [3:0] cap_hi=BAR_INSET+BAR_WIDTH-1-cap_inset;
    wire body_x=cx>=BAR_INSET && cx<BAR_INSET+BAR_WIDTH;
    wire cap_x=cap_row ? (cx>=cap_lo && cx<=cap_hi):body_x;
    wire in_bounds=bounds_ok && h!=0 && py_row>=top_row && cap_x;
    wire cap_head=in_bounds && cap_row && !cap_d[1];

    always @(*) begin
        draw = in_bounds;
        ink = !in_bounds ? 3'd0 : cap_head ? `OSD_INK_HEAD :
              paused_q ? `OSD_INK_DIM : `OSD_INK_FILL;
    end
endmodule
