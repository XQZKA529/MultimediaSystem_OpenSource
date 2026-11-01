`include "../pkg/video_bmp_params.vh"
module video_timing_data
#(
	parameter DATA_WIDTH = 16                       // Video data one clock data width
	,parameter H_ACTIVE = `VBP_H_ACTIVE
	,parameter H_FRONT  = `VBP_H_FRONT
	,parameter H_SYNC   = `VBP_H_SYNC
	,parameter H_BACK   = `VBP_H_BACK
	,parameter V_ACTIVE = `VBP_V_ACTIVE
	,parameter V_FRONT  = `VBP_V_FRONT
	,parameter V_SYNC   = `VBP_V_SYNC
	,parameter V_BACK   = `VBP_V_BACK
	,parameter HS_POL   = 1'b1
	,parameter VS_POL   = 1'b1
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output reg                  read_req,           // Start reading a frame of data     
	input                       read_req_ack,       // Read request response
	//output                      read_en,            // Read data enable
	//input[DATA_WIDTH - 1:0]     read_data,          // Read data
	output                      hs,                 // horizontal synchronization
	output                      vs,                 // vertical synchronization
	output                      de                  // video valid
	//output[DATA_WIDTH - 1:0]    vout_data           // video data
);
wire                   video_hs;
wire                   video_vs;
wire                   video_de;
//delay video_hs video_vs  video_de 2 clock cycles
reg                    video_hs_d0;
reg                    video_vs_d0;
reg                    video_de_d0;
reg                    video_hs_d1;
reg                    video_vs_d1;
reg                    video_de_d1;

//reg[DATA_WIDTH - 1:0]  vout_data_r;
//assign read_en = video_de;
assign hs = video_hs_d1;
assign vs = video_vs_d1;
assign de = video_de_d1;
//assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		video_hs_d0 <= 1'b0;
		video_vs_d0 <= 1'b0;
		video_de_d0 <= 1'b0;
		video_hs_d1 <= 1'b0;
		video_vs_d1 <= 1'b0;
		video_de_d1 <= 1'b0;
	end
	else
	begin
		//delay video_hs video_vs  video_de 2 clock cycles
		video_hs_d0 <= video_hs;
		video_vs_d0 <= video_vs;
		video_de_d0 <= video_de;
		video_hs_d1 <= video_hs_d0;
		video_vs_d1 <= video_vs_d0;
		video_de_d1 <= video_de_d0;		
	end
end
/*
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(video_de_d0)
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
*/
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		read_req <= 1'b0;
	else if(video_vs_d0 & ~video_vs) //vertical synchronization edge (the rising or falling edges are OK)
		read_req <= 1'b1;
	else if(read_req_ack)
		read_req <= 1'b0;
end

color_bar #(
	.H_ACTIVE(H_ACTIVE), .H_FP(H_FRONT), .H_SYNC(H_SYNC), .H_BP(H_BACK),
	.V_ACTIVE(V_ACTIVE), .V_FP(V_FRONT), .V_SYNC(V_SYNC), .V_BP(V_BACK),
	.HS_POL(HS_POL), .VS_POL(VS_POL)
) color_bar_m0(
	.clk(video_clk),
	.rst(rst),
	.hs(video_hs),
	.vs(video_vs),
	.de(video_de),
	.rgb_r(),
	.rgb_g(),
	.rgb_b()
);
endmodule
