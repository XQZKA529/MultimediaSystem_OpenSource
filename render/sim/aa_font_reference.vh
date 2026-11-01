// Independent software-rasterized atlas, not the DUT's ROM/function.
reg [1:0] reference_atlas[0:13299];
reg [4095:0] reference_file;
initial begin
    if(!$value$plusargs("AA_ATLAS=%s",reference_file)) $fatal(1,"Missing AA_ATLAS reference");
    $readmemh(reference_file,reference_atlas);
end
function [1:0] reference_alpha;
    input [7:0] ch;input integer px,py;
    begin
        reference_alpha=0;
        if(ch>=32 && ch<=126 && px>=0 && px<10 && py>=0 && py<14)
            reference_alpha=reference_atlas[(ch-32)*140+py*10+px];
    end
endfunction
function [23:0] reference_blend;
    input [23:0] fg,bg;input [1:0] a;
    reg [7:0] r,g,b;
    begin
        r=(fg[23:16]*a+bg[23:16]*(3-a)+1)/3;
        g=(fg[15:8]*a+bg[15:8]*(3-a)+1)/3;
        b=(fg[7:0]*a+bg[7:0]*(3-a)+1)/3;
        reference_blend={r,g,b};
    end
endfunction
