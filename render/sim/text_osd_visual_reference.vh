// Independent geometry, glyph and integer-blend oracle; no DUT internals.
    function [7:0] glass_channel;
        input [7:0] src,tint; input integer weight; integer sum;
        begin
            if(weight==2) sum=src*2+tint*2;
            else if(weight==3) sum=src*3+tint;
            else sum=src*4;
            glass_channel=sum/4;
        end
    endfunction
    function [23:0] glass_rgb;
        input [23:0] src,tint; input integer weight;
        begin glass_rgb={glass_channel(src[23:16],tint[23:16],weight),
                         glass_channel(src[15:8],tint[15:8],weight),
                         glass_channel(src[7:0],tint[7:0],weight)}; end
    endfunction
    function [23:0] golden;
        input integer x,y;input [23:0] base;
        integer row,col,gx,gy,fr,lo,hi,f,banner_x,banner_width,banner_dx,prev_col,prev_gx;reg [7:0] ch,prev_ch;reg selected;reg [1:0] prev_a;reg [23:0] bg;
        begin
            golden=base;row=0;col=0;ch=32;selected=0;
            banner_width=12*view[`TEXT_OSD_LEN];
            if(view[`TEXT_OSD_LEN]>74) begin banner_x=(REFERENCE_SCREEN_W*15)/100;banner_width=(REFERENCE_SCREEN_W*70)/100;end
            else banner_x=(REFERENCE_SCREEN_W-banner_width)/2;
            if(active && page && x>=REFERENCE_WIN_X && x<REFERENCE_WIN_X+388 && y>=REFERENCE_WIN_Y && y<REFERENCE_WIN_Y+148) begin
                if(x<REFERENCE_WIN_X+2 || x>=REFERENCE_WIN_X+386 || y<REFERENCE_WIN_Y+2 || y>=REFERENCE_WIN_Y+146) golden=24'hD6DBE1;
                else begin
                    row=(y-REFERENCE_WIN_Y-2)/16;col=(x-REFERENCE_WIN_X-2)/12;ch=chars[row*32+col];f=view[`TEXT_OSD_FOCUS];
                    if(f<2) begin fr=2;lo=f==0 ? 0:25;hi=f==0 ? 9:29;end
                    else begin fr=4+(f-2)/7;lo=((f-2)%7)*4;hi=lo+3;
                        if(f==28) begin lo=20;hi=26;end
                        if(f==29) begin lo=27;hi=31;end
                    end
                    selected=row==fr && col>=lo && col<=hi;
                    golden=glass_rgb(base,selected ? 24'h3A3F46:24'h14171B,selected ? 2:3);
                    gx=(x-REFERENCE_WIN_X-2)%12;gy=(y-REFERENCE_WIN_Y-2)%16;
                    golden=reference_blend(24'hF5F7FA,golden,reference_alpha(ch,gx,gy));
                end
            end else if(!active && !diag && view[`TEXT_OSD_ENABLE] && view[`TEXT_OSD_LEN]!=0 &&
                        x>=banner_x && x<banner_x+banner_width && y>=64 && y<80) begin
                banner_dx=x-banner_x;
                col=banner_dx/12;ch=view[col*8 +: 8];gx=banner_dx%12;gy=y-64;
                bg=base;
                if(x>banner_x) begin
                    prev_col=(banner_dx-1)/12;prev_gx=(banner_dx-1)%12;prev_ch=view[prev_col*8 +: 8];
                    prev_a=reference_alpha(prev_ch,prev_gx,gy);
                    if(prev_a!=0) bg=reference_blend(24'h20252C,base,1);
                end
                golden=reference_blend(24'hF5F7FA,bg,reference_alpha(ch,gx,gy));
            end
        end
    endfunction
    task row_text;input integer row;input [255:0] text;integer j;
        begin for(j=0;j<32;j=j+1) chars[row*32+j]=text[(31-j)*8 +: 8];end
    endtask
    task build_chars;integer j;
        begin
            for(j=0;j<288;j=j+1) chars[j]=32;
            row_text(0,"TEXT OSD                        ");
            row_text(2,"[OSD: OFF]               [CLR]  ");
            row_text(4," A   B   C   D   E   F   G      ");
            row_text(5," H   I   J   K   L   M   N      ");
            row_text(6," O   P   Q   R   S   T   U      ");
            row_text(7," V   W   X   Y   Z  [SPACE][DEL]");
            row_text(8,"2/8/4/6 MOVE 5 OK # BACK        ");
            chars[24]="0"+view[`TEXT_OSD_LEN]/100;
            chars[25]="0"+(view[`TEXT_OSD_LEN]/10)%10;chars[26]="0"+view[`TEXT_OSD_LEN]%10;
            chars[27]="/";chars[28]="2";chars[29]="5";chars[30]="6";
            start=view[`TEXT_OSD_LEN]>29 ? view[`TEXT_OSD_LEN]-29:0;
            visible_len=view[`TEXT_OSD_LEN]-start;
            chars[32]=start!=0 ? "<":"[";chars[63]="]";
            for(j=0;j<visible_len;j=j+1) chars[33+j]=view[(start+j)*8 +: 8];
            chars[33+visible_len]="_";
            if(view[`TEXT_OSD_ENABLE]) begin chars[64+7]="N";chars[64+8]=" ";end
        end
    endtask
