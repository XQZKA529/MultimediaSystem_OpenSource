// Four area-coverage levels. All callers use fixed foreground/background
// palettes, so synthesis reduces these expressions to small palette muxes.
function [7:0] font_blend_channel;
    input [7:0] foreground,background;
    input [1:0] coverage;
    reg [9:0] value;
    begin
        case(coverage)
        0: font_blend_channel=background;
        1: begin value={2'd0,foreground}+({2'd0,background}<<1)+10'd1; font_blend_channel=value/3; end
        2: begin value=({2'd0,foreground}<<1)+{2'd0,background}+10'd1; font_blend_channel=value/3; end
        3: font_blend_channel=foreground;
        endcase
    end
endfunction
function [23:0] font_blend;
    input [23:0] foreground,background;
    input [1:0] coverage;
    begin
        font_blend={font_blend_channel(foreground[23:16],background[23:16],coverage),
                    font_blend_channel(foreground[15:8],background[15:8],coverage),
                    font_blend_channel(foreground[7:0],background[7:0],coverage)};
    end
endfunction
