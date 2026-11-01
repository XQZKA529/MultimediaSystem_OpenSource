// Converts compact 32-bit SDRAM words back to RGB888 pixels.
// Two alternating 3-word banks decouple the FIFO cadence from the display:
// while one bank emits four pixels, the other bank fetches three words.
// All selects are fixed-width muxes; there is no timing-heavy barrel shifter.
module rgb888_word_reader (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire        fifo_empty,
    output wire        fifo_read_en,
    input  wire [31:0] fifo_read_data,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] pixel_rgb,
    output reg         underflow_sticky,
    // 本拍像素有效：跟随 de_out，且该拍确实取到了 bank 数据（未欠载）。
    // 两路 reader 同接相同帧开始/时序 ⇒ 同一坐标的 hit 位必然同拍；
    // 混合器据此逐像素校验两路坐标配对。
    output reg         pixel_valid
);
    reg [31:0] bank0_w0, bank0_w1, bank0_w2;
    reg [31:0] bank1_w0, bank1_w1, bank1_w2;
    reg        bank0_valid, bank1_valid;
    reg        active_bank;
    reg [1:0]  pixel_phase;

    reg        fill_bank;
    reg [1:0]  issue_index;
    reg        read_pending;
    reg        pending_bank;
    reg [1:0]  pending_index;

    wire fill_bank_valid = fill_bank ? bank1_valid : bank0_valid;
    assign fifo_read_en = !fifo_empty && !fill_bank_valid && (issue_index < 2'd3);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bank0_w0 <= 0; bank0_w1 <= 0; bank0_w2 <= 0;
            bank1_w0 <= 0; bank1_w1 <= 0; bank1_w2 <= 0;
            bank0_valid <= 1'b0; bank1_valid <= 1'b0;
            active_bank <= 1'b0; pixel_phase <= 2'd0;
            fill_bank <= 1'b0; issue_index <= 2'd0;
            read_pending <= 1'b0; pending_bank <= 1'b0; pending_index <= 2'd0;
            hs_out <= 1'b0; vs_out <= 1'b0; de_out <= 1'b0;
            pixel_rgb <= 24'd0; underflow_sticky <= 1'b0;
            pixel_valid <= 1'b0;
        end else begin
            hs_out <= hs_in;
            vs_out <= vs_in;
            de_out <= de_in;
            // pixel_valid 与 pixel_rgb 同拍产生：de_in 有效且命中 bank 数据
            // 才算一次可信像素输出（欠载时 pixel_valid=0）。
            pixel_valid <= de_in && ((!active_bank && bank0_valid) || (active_bank && bank1_valid));

            read_pending <= fifo_read_en;
            if (fifo_read_en) begin
                pending_bank  <= fill_bank;
                pending_index <= issue_index;
                issue_index   <= issue_index + 1'b1;
            end

            if (read_pending) begin
                if (!pending_bank) begin
                    case (pending_index)
                        2'd0: bank0_w0 <= fifo_read_data;
                        2'd1: bank0_w1 <= fifo_read_data;
                        default: begin bank0_w2 <= fifo_read_data; bank0_valid <= 1'b1; end
                    endcase
                end else begin
                    case (pending_index)
                        2'd0: bank1_w0 <= fifo_read_data;
                        2'd1: bank1_w1 <= fifo_read_data;
                        default: begin bank1_w2 <= fifo_read_data; bank1_valid <= 1'b1; end
                    endcase
                end
                if (pending_index == 2'd2) begin
                    fill_bank   <= ~pending_bank;
                    issue_index <= 2'd0;
                end
            end

            if (frame_start) begin
                bank0_valid <= 1'b0; bank1_valid <= 1'b0;
                active_bank <= 1'b0; pixel_phase <= 2'd0;
                fill_bank <= 1'b0; issue_index <= 2'd0; read_pending <= 1'b0;
            end else if (de_in) begin
                if ((!active_bank && bank0_valid) || (active_bank && bank1_valid)) begin
                    if (!active_bank) begin
                        case (pixel_phase)
                            2'd0: pixel_rgb <= bank0_w0[31:8];
                            2'd1: pixel_rgb <= {bank0_w0[7:0],bank0_w1[31:16]};
                            2'd2: pixel_rgb <= {bank0_w1[15:0],bank0_w2[31:24]};
                            default: pixel_rgb <= bank0_w2[23:0];
                        endcase
                    end else begin
                        case (pixel_phase)
                            2'd0: pixel_rgb <= bank1_w0[31:8];
                            2'd1: pixel_rgb <= {bank1_w0[7:0],bank1_w1[31:16]};
                            2'd2: pixel_rgb <= {bank1_w1[15:0],bank1_w2[31:24]};
                            default: pixel_rgb <= bank1_w2[23:0];
                        endcase
                    end
                    if (pixel_phase == 2'd3) begin
                        if (active_bank) bank1_valid <= 1'b0;
                        else             bank0_valid <= 1'b0;
                        active_bank <= ~active_bank;
                        pixel_phase <= 2'd0;
                    end else begin
                        pixel_phase <= pixel_phase + 1'b1;
                    end
                end else begin
                    pixel_rgb <= 24'd0;
                    underflow_sticky <= 1'b1;
                end
            end else begin
                pixel_rgb <= 24'd0;
            end
        end
    end
endmodule
