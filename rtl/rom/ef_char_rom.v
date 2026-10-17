//
// EF9340/EF9341 (G7400 "Videopac+") character generator ROM
//
// Behavioural, synchronous-read (1 clock registered output) loadable
// memory so Quartus can map it onto M10K block RAM (a large async-read
// memory does not fit any block RAM primitive and gets synthesized as
// LUT/register fabric, which is far too large to fit the FPGA - see
// repo memory file g7400-implementation-plan.md). ef9340_video.vhd issues
// the read address one dot-clock ahead of when the data is actually
// consumed (see the dot_s=1 pre-fetch in the render process) to hide
// this 1 cycle of latency.
//
// 2560 x 8 bit (12 bit address, but only 0..2559 valid: (set(1)&code(7))
// packed as an 8 bit index, *10 + slice(0..9)) - matches MAME's reference
// charset_ef9340_1.rom layout exactly (256 codes * 10 slices), so a
// standard MAME EF9340/9341 charset dump loads via the OSD as-is, with no
// repacking. Loaded at runtime the same way as char_rom (ioctl wren
// pulses write mem[address]) - the F4 "Load G7400 charset" OSD entry can
// still replace it, same as F3 can replace the built-in i8244 charset.
//
// Pre-initialized from charset_ef9340_g7400.hex (a plain $readmemh dump
// of the same MAME charset_ef9340_1.rom referenced above) so G7400 text
// renders correctly out of the box, matching how char_rom below is
// pre-initialized from charset_videopac.hex - without this, mem starts
// out unknown/zero on real hardware and every EF9340 character prints
// as blank until the user manually loads a charset via the OSD.
//
module ef_char_rom
(
	input        clock,
	input [11:0] address,
	input  [7:0] data,
	input        wren,
	output reg [7:0] q
);

	reg [7:0] mem [0:2559];

	initial $readmemh("charset_ef9340_g7400.hex", mem);

	always @(posedge clock) begin
		if (wren) mem[address] <= data;
		q <= mem[address];
	end

endmodule

