`timescale 1ns/1ps
`include "../pkg/video_bmp_params.vh"
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_FIFO_ADDR_BITS   = 10,
	parameter WRITE_V_FLIP           = `VBP_WRITE_V_FLIP, // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = `VBP_LINE_WORDS,  // SDRAM words per line (not pixels)
	parameter FRAME_HEIGHT           = `VBP_V_ACTIVE
) 
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_dual_active,
	output                           read_finish,                // data read module read request finish
    output [1:0]                     read_selected_index,
    output                           read_handoff_toggle,
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data (lane0)
	output                           read_empty,                 // read-clock-domain FIFO empty flag (lane0)

	// ---- 第二路（新图）读接口，动画期使用 ----
	input                            read_en1,                   // lane1 读使能
	output[READ_DATA_BITS  - 1:0]    read_data1,                 // lane1 读数据
	output                           read_empty1,                // lane1 空标志
	input[ADDR_BITS - 1:0]           read_addr_lane1,            // lane1 源基地址
	input[1:0]                       read_index_lane1,           // lane1 源索引
	input                            read_lane1_en,              // 本帧是否启用 lane1
	input                            read_slide_en,
	input [9:0]                      read_slide_rows,
	// 双路就绪（两路读 FIFO 均备妥、无读突发在途）
	output                           read_ready,
	// 动画期禁止图片写入（两张缓存都在被读，不允许第三方覆盖）
	input                            write_block,
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
    input                            write_abort,
    output                           write_abort_ack,
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data,                // write data
	output                           write_full,                 // write-clock-domain FIFO full flag
	output                           write_sector_ready          // write FIFO has enough elastic headroom to start SD burst

);
wire[BURST_BITS - 1:0]                           wrusedw;                    // write used words
wire[WRITE_FIFO_ADDR_BITS - 1:0]                 rdusedw;                    // write FIFO read-domain occupancy
wire[WRITE_FIFO_ADDR_BITS - 1:0]                 write_wrusedw;
wire[8:0]                                        wrusedw0, wrusedw1;         // 两路读 FIFO 的占用量
wire                                             read_urgent;                // 读通路迫切（门控写突发）
// 双路读 FIFO 的写使能：按当前突发归属分派 Sdr_rd_en
// （必须在 FIFO 例化之前声明，否则例化端口会先引用到隐式 1 位网）
wire                                             read_lane_sel;              // 0: 当前突发写入 lane0；1: 写入 lane1
wire                                             Sdr_rd_en_lane0;
wire                                             Sdr_rd_en_lane1;
assign Sdr_rd_en_lane0 = Sdr_rd_en & ~read_lane_sel;
assign Sdr_rd_en_lane1 = Sdr_rd_en &  read_lane_sel;

// Admit a network payload only with 256 words plus 32 words of headroom.
// The 1024-word FIFO absorbs SDRAM arbitration and refresh jitter.
// write_block（动画期）为 1 时整体谢绝新的图片写入：两张帧缓存都在被
// 双路读取，任何第三方覆盖都会破坏正在混合的画面。
assign write_sector_ready = ~write_block && ~write_full &&
                            (write_wrusedw <= ((1 << WRITE_FIFO_ADDR_BITS)-288));

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear (lane0)
wire                                 read_fifo_aclr1;            // fifo Asynchronous clear (lane1)
wire                                 write_fifo_aclr;            // fifo Asynchronous clear

wire O_wr_busy;
wire O_rd_busy;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy;//读指令还没有过去十个时钟;因为写指令优先，不需要在意下个时钟是否是读指令
assign App_wr_dm = 4'b0000;

//instantiate an asynchronous FIFO 
wfifo_32_32_512 #(
	.ADDR_WIDTH_W              (WRITE_FIFO_ADDR_BITS),
	.ADDR_WIDTH_R              (WRITE_FIFO_ADDR_BITS),
	.AL_FULL_NUM               ((1 << WRITE_FIFO_ADDR_BITS)-3)
) write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr          ),          // Asynchronous clear
	.we                      	(write_en                 ),          // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_data               ),          // Input Data
	.empty_flag                 (                         ),          // Read side Empty flag
	.full_flag                  (write_full               ),          // Write side Full flag
	.wrusedw                	(write_wrusedw            ),          // Write-clock occupancy
	.rdusedw                	(rdusedw                  ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.FIFO_ADDR_BITS             (WRITE_FIFO_ADDR_BITS     ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
	.read_urgent                (read_urgent              ),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
    .write_abort                (write_abort),
    .write_abort_ack            (write_abort_ack),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr             ),          // Asynchronous clear
	.we                     	(Sdr_rd_en_lane0   			),          // Write Request
	.re                     	(read_en                    ),          // Read Request
	.di                      	(Sdr_rd_dout                ),          // Input Data
	.empty_flag					(read_empty                 ),          // Read side Empty flag
	.full_flag					(                           ),          // Write side Full flag
	.wrusedw                	(wrusedw0         	  	  	),          // Read Used Words
	.rdusedw                	(                  			 ),          // Write Used Words
	.dout						(read_data                  )
);

// 第二路读 FIFO（新图），与 lane0 同构，独立清空/占用统计
rfifo_32_32_512 read_buf1
	(
	.clkr                     	(read_clk                   ),
	.clkw                     	(mem_clk                    ),
	.rst                      	(read_fifo_aclr1            ),
	.we                     	(Sdr_rd_en_lane1   			),
	.re                     	(read_en1                   ),
	.di                      	(Sdr_rd_dout                ),
	.empty_flag					(read_empty1                ),
	.full_flag					(                           ),
	.wrusedw                	(wrusedw1         	  	  	),
	.rdusedw                	(                  			 ),
	.dout						(read_data1                 )
);

// 统一读调度器：256 字突发、占用低者优先、相同时轮流
frame_fifo_read_dual
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.FIFO_DEPTH                 (512                      ),
	.LANES                      (2                        ),
	.LINE_WORDS                 (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             ),
	.SPLIT_LINE                 (FRAME_HEIGHT/2           )
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),

    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (read_req                 ),
    .read_selected_index        (read_selected_index),
    .read_handoff_toggle        (read_handoff_toggle),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
	.read_addr_lane1            (read_addr_lane1          ),
	.read_index_lane1           (read_index_lane1         ),
	.read_lane1_en              (read_lane1_en            ),
	.read_slide_en              (read_slide_en            ),
	.read_slide_rows            (read_slide_rows          ),
	.lane0_lane1_sel            (read_lane_sel            ),
	.fifo_aclr0                 (read_fifo_aclr           ),
	.fifo_aclr1                 (read_fifo_aclr1          ),
	.wrusedw0                   ({1'b0,wrusedw0}                 ),
	.wrusedw1                   ({1'b0,wrusedw1}                 ),
	.read_dual_active           (read_dual_active),
	.read_ready                 (read_ready               ),
	.read_urgent                (read_urgent              )
);

endmodule
