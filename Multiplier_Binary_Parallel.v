
//# A Parallel Binary Multiplier

// A generic signed multiplier module, with the inference left to the CAD
// tool. Any attributes to control the synthesis of the multiplier should be
// applied, in the text of the enclosing module, to this whole module. The
// attributes vary too much and none provide the default automatic inference
// choices made by the CAD tool (e.g.: logic for narrow widths, DSP blocks for
// larger widths), which are almost always the right choices.

//## Width and Signedness

// Both input word widths are parameterized separately so as to infer the
// smallest multiplier necessary to generate a full product, whose width is
// the sum of the widths of the inputs. *The user must manually supply that
// total width to the connecting wires in the enclosing module, as there is no
// way to introspect parameter values inside a module.*

// The multiplier inference is limited to signed integers as the common case
// and to keep the code simple. If you must treat the inputs as unsigned
// integers, first extend them with a constant zero most-significant bit to
// force them positive. Yes, this may cost some area and may slow down the
// logic slightly, but if a single extra bit of width breaks your timing
// closure, then your design's timing closure was already on its last legs,
// and perhaps you need to allow more pipelining and/or use a narrower width.

//## Pipelining

// At the time of writing (March 2020), retiming of external registers into an
// inferred multiplier does not work in Vivado, so we cannot simply place
// a [Register Pipeline](./Register_Pipeline.html) before and after the
// multiplier module to help it meet timing if necessary.

// Instead, we must connect the input and output pipelines and the multiplier
// all together in a single clocked always block to match the recommended HDL
// style for multiplier inference (UG901, *Vivado Design Suite User Guide:
// Synthesis*). This code also works under Intel Quartus Prime as its HDL
// coding guidelines for inferring multipliers are the same (UG-20131, *Intel
// Quartus Prime Pro Edition User Guide: Design Recommendations*).

// **Note**: *you must disable shift register extraction during synthesis to
// force implementation of the pipelines as registers which can be retimed and
// can be placed-and-routed independently.* Else your pipeline may be
// implemented as shift registers which, while compact, won't provide any
// pipelining benefits. *Shift register extraction is enabled by default in
// Vivado and Quartus synthesis.*

// Pipelining multipliers, although optional, benefits both synthesis and
// place-and-route: 

// * At a minimum, single input and output pipeline registers will get packed
// into the input and output registers of the DSP blocks, easing timing and
// saving area.
// * Particularly for wider multipliers, the inferred adder tree which merges
// the partial products from multiple DSP blocks may need an output pipeline
// to meet timing. (The input pipeline does not appear to retime through the
// DSP blocks.)
// * Finally, since DSP blocks only exist in certain fixed locations on FPGAs,
// abundant pipelining frees the CAD tool to place-and-route the DSP blocks
// away from other timing-critical logic, which would otherwise misleadinly
// appear to be the critical path (due to poor routing) and lead you to waste
// effort trying to optimize the wrong logic!
// For example, I've once had to add a total of 24 pipeline stages (12 input,
// 12 output) to a very wide multiplier with a 100-bit product to allow other
// 100-bit arithmetic logic to meet timing.

`default_nettype none

module Multiplier_Binary_Parallel
#(
    parameter WORD_WIDTH_A      = 0,
    parameter WORD_WIDTH_B      = 0,
    parameter INPUT_PIPE_DEPTH  = 0,
    parameter OUTPUT_PIPE_DEPTH = 0,

    // Don't set at instantiation, except in IPI
    parameter PRODUCT_WIDTH = WORD_WIDTH_A + WORD_WIDTH_B
)
(
    // Unused if no input/output pipelines (combinational multiplier)
    // verilator lint_off UNUSED
    input  wire                             clock,
    // verilator lint_on  UNUSED
    input  wire signed [WORD_WIDTH_A-1:0]   A_in,
    input  wire signed [WORD_WIDTH_B-1:0]   B_in,
    output reg  signed [PRODUCT_WIDTH-1:0]  product_out
);

    localparam WORD_ZERO_A  = {WORD_WIDTH_A{1'b0}};
    localparam WORD_ZERO_B  = {WORD_WIDTH_B{1'b0}};
    localparam PRODUCT_ZERO = {PRODUCT_WIDTH{1'b0}};

    initial begin
        product_out = PRODUCT_ZERO;
    end

// If their depth is greater than zero, create the input and/or output
// pipelines. These **MUST** be declared as `signed`, else the multiplication
// will be inferred as unsigned and calculate the wrong results when given
// negative integers.

// Then, if necessary, we connect the inputs, the pipelines, and the
// multiplier all together in a single clocked always block. The CAD tool with
// infer DSP blocks and adders, and retime the pipeline registers as necessary
// if retiming is enabled in your CAD tool. *Retiming is off by default in
// Vivado and Quartus synthesis.*

// We write the pipelines using the idiom of peeling out the first loop
// iteration so we never generate a negative index with `i-1`. Note the
// initialization value of `i` in the for-loops.

// There are four possible cases of zero and non-zero (positive) pipeline
// depths, so we generate the correct code, based on the HDL guidelines, for
// each case. A negative pipe depth would result in negative array ranges,
// *which is legal in Verilog-2001*, though I have no idea what it's for. To
// avoid strange corner cases, no code is generated for negative values, which
// will cause the design to fail to elaborate.

    generate

        // No pipelines (combinational multiplier)
        if ((INPUT_PIPE_DEPTH == 0) && (OUTPUT_PIPE_DEPTH == 0)) begin: no_pipe
            always @(*) begin
                product_out = A_in * B_in;
            end
        end

        // Input pipeline only
        else if ((INPUT_PIPE_DEPTH > 0) && (OUTPUT_PIPE_DEPTH == 0)) begin: in_pipe
            reg signed [WORD_WIDTH_A-1:0]  input_pipe_A  [INPUT_PIPE_DEPTH-1:0];
            reg signed [WORD_WIDTH_B-1:0]  input_pipe_B  [INPUT_PIPE_DEPTH-1:0];

            integer i;

            initial begin
                for (i=0; i < INPUT_PIPE_DEPTH; i=i+1) begin
                    input_pipe_A [i] = WORD_ZERO_A;
                    input_pipe_B [i] = WORD_ZERO_B;
                end
            end

            always @(posedge clock) begin
                input_pipe_A[0] <= A_in;
                input_pipe_B[0] <= B_in;

                for (i=1; i < INPUT_PIPE_DEPTH; i=i+1) begin: per_input
                    input_pipe_A [i] <= input_pipe_A [i-1];
                    input_pipe_B [i] <= input_pipe_B [i-1];
                end
            end

            // Corner case: it isn't possible to put this in the clocked
            // always block without registering the output as a consequence.
            always @(*) begin
                product_out = input_pipe_A [INPUT_PIPE_DEPTH-1] * input_pipe_B [INPUT_PIPE_DEPTH-1];
            end
        end

        // Output pipeline only
        else if ((INPUT_PIPE_DEPTH == 0) && (OUTPUT_PIPE_DEPTH > 0)) begin: out_pipe
            reg signed [PRODUCT_WIDTH-1:0] output_pipe   [OUTPUT_PIPE_DEPTH-1:0];

            integer i;

            initial begin
                for (i=0; i < OUTPUT_PIPE_DEPTH; i=i+1) begin
                    output_pipe [i] = PRODUCT_ZERO;
                end
            end

            always @(posedge clock) begin
                output_pipe [0] <= A_in * B_in;

                for (i=1; i < OUTPUT_PIPE_DEPTH; i=i+1) begin: per_output
                    output_pipe [i] <= output_pipe [i-1];
                end
            end

            always @(*) begin
                product_out = output_pipe [OUTPUT_PIPE_DEPTH-1];
            end
        end

        // Both input and output pipelines
        else if ((INPUT_PIPE_DEPTH > 0) && (OUTPUT_PIPE_DEPTH > 0)) begin: in_out_pipe
            reg signed [WORD_WIDTH_A-1:0]  input_pipe_A  [INPUT_PIPE_DEPTH-1:0];
            reg signed [WORD_WIDTH_B-1:0]  input_pipe_B  [INPUT_PIPE_DEPTH-1:0];
            reg signed [PRODUCT_WIDTH-1:0] output_pipe   [OUTPUT_PIPE_DEPTH-1:0];

            integer i;

            initial begin
                for (i=0; i < INPUT_PIPE_DEPTH; i=i+1) begin
                    input_pipe_A [i] = WORD_ZERO_A;
                    input_pipe_B [i] = WORD_ZERO_B;
                end
                for (i=0; i < OUTPUT_PIPE_DEPTH; i=i+1) begin
                    output_pipe [i] = PRODUCT_ZERO;
                end
            end

            always @(posedge clock) begin
                input_pipe_A[0] <= A_in;
                input_pipe_B[0] <= B_in;

                for (i=1; i < INPUT_PIPE_DEPTH; i=i+1) begin: per_input
                    input_pipe_A [i] <= input_pipe_A [i-1];
                    input_pipe_B [i] <= input_pipe_B [i-1];
                end

                output_pipe [0] <= input_pipe_A [INPUT_PIPE_DEPTH-1] * input_pipe_B [INPUT_PIPE_DEPTH-1];

                for (i=1; i < OUTPUT_PIPE_DEPTH; i=i+1) begin: per_output
                    output_pipe [i] <= output_pipe [i-1];
                end

            end

            always @(*) begin
                product_out = output_pipe [OUTPUT_PIPE_DEPTH-1];
            end
        end

    endgenerate

endmodule

