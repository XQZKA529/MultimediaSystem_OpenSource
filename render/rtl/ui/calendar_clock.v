// Calendar and draft belong to the bus domain. Playback/link resets never reset it.
module calendar_clock #(parameter integer CLK_HZ=100000000)(
    input wire clk,rst,edit_enable,cancel,up,down,left,right,confirm,
    output reg [32:0] live,output reg [32:0] draft,
    output reg [2:0] focus,output reg editing
);
    // {year since 2000[6:0],month[3:0],day[4:0],hour[4:0],minute[5:0],second[5:0]}
    localparam [32:0] DEFAULT_TIME={7'd0,4'd1,5'd1,5'd0,6'd0,6'd0};
    reg [$clog2(CLK_HZ)-1:0] fraction;
    reg ready_d;
    wire second_tick=fraction==CLK_HZ-1;
    wire apply=editing && edit_enable && !cancel && confirm && focus==6;
    function [4:0] last_day;
        input [6:0] yr;input [3:0] mon;
        begin
            case(mon)
                2:last_day=yr[1:0]==0 ? 29:28;
                4,6,9,11:last_day=30;
                default:last_day=31;
            endcase
        end
    endfunction
    function [32:0] increment;
        input [32:0] t;
        reg [6:0] yr;reg [3:0] mon;reg [4:0] day,hr;reg [5:0] mn,ss;
        begin
            {yr,mon,day,hr,mn,ss}=t;
            if(ss!=59) ss=ss+1'b1;
            else begin ss=0;
                if(mn!=59) mn=mn+1'b1;
                else begin mn=0;
                    if(hr!=23) hr=hr+1'b1;
                    else begin hr=0;
                        if(day!=last_day(yr,mon)) day=day+1'b1;
                        else begin day=1;
                            if(mon!=12) mon=mon+1'b1;
                            else begin mon=1;yr=yr==99 ? 0:yr+1'b1;end
                        end
                    end
                end
            end
            increment={yr,mon,day,hr,mn,ss};
        end
    endfunction
    reg [32:0] adjusted;
    reg [6:0] y;reg [3:0] m;reg [4:0] d,h;reg [5:0] n,s;
    always @(*) begin
        {y,m,d,h,n,s}=draft;
        case(focus)
            0:y=right ? (y==99 ? 0:y+1'b1):(y==0 ? 99:y-1'b1);
            1:m=right ? (m==12 ? 1:m+1'b1):(m==1 ? 12:m-1'b1);
            2:d=right ? (d==last_day(y,m) ? 1:d+1'b1):(d==1 ? last_day(y,m):d-1'b1);
            3:h=right ? (h==23 ? 0:h+1'b1):(h==0 ? 23:h-1'b1);
            4:n=right ? (n==59 ? 0:n+1'b1):(n==0 ? 59:n-1'b1);
            5:s=right ? (s==59 ? 0:s+1'b1):(s==0 ? 59:s-1'b1);
            default:begin end
        endcase
        if(d>last_day(y,m)) d=last_day(y,m);
        adjusted={y,m,d,h,n,s};
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin live<=DEFAULT_TIME;draft<=DEFAULT_TIME;fraction<=0;focus<=0;editing<=0;ready_d<=0;end
        else begin
            ready_d<=edit_enable;
            if(apply) begin live<=draft;fraction<=0;end
            else begin fraction<=second_tick ? 0:fraction+1'b1;if(second_tick) live<=increment(live);end
            if(cancel || !edit_enable) begin editing<=0;focus<=0;end
            else if(!ready_d) begin draft<=live;editing<=1;focus<=0;end
            else if(editing) begin
                if(up) focus<=focus==0 ? 6:focus-1'b1;
                else if(down) focus<=focus==6 ? 0:focus+1'b1;
                else if(left || right) draft<=adjusted;
            end
        end
    end
endmodule
