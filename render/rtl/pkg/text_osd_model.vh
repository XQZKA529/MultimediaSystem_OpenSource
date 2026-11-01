`ifndef TEXT_OSD_MODEL_VH
`define TEXT_OSD_MODEL_VH
// Full model layout below is retained for simulation reference only.
// Production interfaces transfer 13-bit {enable,focus,length} and RAM bytes.
// Render-local model. Byte i occupies TEXT[i*8 +: 8]; length masks stale RAM.
// The editor stores up to 256 ASCII bytes. A 9-bit length can represent the
// full capacity while the 8-bit RAM address still ends at byte 255.
`define TEXT_OSD_MAX_LEN 256
`define TEXT_OSD_BYTES `TEXT_OSD_MAX_LEN
`define TEXT_OSD_TEXT_W (`TEXT_OSD_BYTES*8)
`define TEXT_OSD_LEN_W 9
`define TEXT_OSD_TEXT (`TEXT_OSD_TEXT_W-1):0
`define TEXT_OSD_LEN (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W-1):`TEXT_OSD_TEXT_W
`define TEXT_OSD_FOCUS (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W+4):(`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W)
`define TEXT_OSD_ENABLE (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W+5)
`define TEXT_OSD_MODEL_W (`TEXT_OSD_TEXT_W+`TEXT_OSD_LEN_W+6)
`define TEXT_OSD_META_W 15
`define TEXT_OSD_VIEW_LEN 8:0
`define TEXT_OSD_VIEW_FOCUS 13:9
`define TEXT_OSD_VIEW_ENABLE 14
`endif
