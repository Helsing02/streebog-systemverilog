// -----------------------------------------------------------------------------
// Padding
// Byte-level padding unit for 512-bit input data blocks.
// Inserts 0x01 and 0x00 padding bytes according to the 'keep' mask.
//
// Operation:
//   - If i_keep[n] == 1 → keep input byte i_data[n]
//   - If i_keep[n] == 0 → replace with padding pattern
//
// Padding rule:
//   - First unused byte is replaced with 0x01
//   - All subsequent unused bytes are filled with 0x00
//
// Interface:
//  - i_data : 512-bit input data block (64 bytes)
//  - i_keep : 64-bit mask, 1 bit per byte (1 = valid byte)
//  - o_data : 512-bit padded data block
//
// Notes:
//  - Fully combinational logic.
//  - Designed for message block padding before hash/LPSX transform.
// -----------------------------------------------------------------------------

module padding (
    input  logic [511:0] i_data,    // Input data block for padding
    input  logic [63:0]  i_keep,    // Input keep information
    output logic [511:0] o_data     // Output padded data block
);

// -----------------------------------------------------------------------------
// Handle first byte separately:
// If keep[0] = 1 → pass through input byte
// Else → insert 0x01 as padding start marker
// -----------------------------------------------------------------------------
assign o_data[0 +: 8] = (i_keep[0] == 1) ? i_data[0 +: 8] : 8'h01;

// -----------------------------------------------------------------------------
// Generate padding logic for remaining 63 bytes.
// For each byte position i:
//   - If i_keep[i] = 1  → pass input byte
//   - Else if previous i_keep[i-1] = 1 → insert 0x01
//   - Else → insert 0x00
// -----------------------------------------------------------------------------
genvar i;
generate
    for (i = 1; i < 64; i++) begin : padding_loop
        // Apply conditional byte substitution based on keep mask.
        assign o_data[i*8 +: 8] = (i_keep[i] == 1)   ? i_data[i*8 +: 8] :
                                  (i_keep[i-1] == 1) ? 8'h01            :
                                                       8'h00;
    end
endgenerate

// -----------------------------------------------------------------------------
// End of Padding
// -----------------------------------------------------------------------------
endmodule : padding
