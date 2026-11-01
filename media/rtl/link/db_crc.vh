// CRC-32/ISO-HDLC: reflected polynomial, init ffffffff, final xor ffffffff.
function [31:0] db_crc_byte;
    input [31:0] crc;
    input [7:0] value;
    reg [31:0] work_crc;
    integer crc_i;
    begin
        work_crc = crc ^ value;
        for (crc_i=0; crc_i<8; crc_i=crc_i+1)
            work_crc = work_crc[0] ? (work_crc >> 1) ^ 32'hedb88320 : work_crc >> 1;
        db_crc_byte = work_crc;
    end
endfunction
