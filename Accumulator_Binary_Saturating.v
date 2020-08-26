
//# Signed Binary Accumulator, with Saturation

// Adds the signed `increment_value` to the signed `accumulated_value` when
// `increment_valid` is pulsed high *for one cycle*. A new increment may be
// added when `increment_done` pulses high, in the same cycle if necessary. 

// Pulsing `load_valid` high for one cycle replaces the `accumulated_value`
// with the `load_value`. A new load can be done when `load_done` pulses high,
// in the same cycle if necessary.

// Pulsing `clear` high for one cycle puts the accumulator back at
// `INITIAL_VALUE`. The accumulator can be cleared again once `clear_done`
// pulses high, in the same cycle if necessary.

// Deasserting `clock_enable` freezes the accumulator: new increments, loads,
// and clears are ignored, the internal pipeline (if any) holds steady, and
// all outputs remain static.

// When chaining accumulators, which may happen if you are incrementing in
// unusual bases where each digit has its own accumulator, AND the `carry_out`
// of the previous accumulator with the signal fed to the `increment_valid`
// input of the next accumulator. The `carry_in` is kept for generality.

//## Saturation

// If the increment **or the load** would cause the accumulator to go past the
// signed minimum or maximum limits, the accumulator will saturate at the
// nearest limit value and also raise one or more of the min/max limit signals
// until the next operation. **The maximum limit must be greater or equal than
// the minimum limit.** If the limits are reversed, such that max_limit
// < min_limit, the result will be meaningless.

//## Pipelining and Concurrency

// This module is pipelined since we are chaining adder/subtractors together
// inside the
// [Adder_Subtractor_Binary_Saturating](./Adder_Subtractor_Binary_Saturating.html)
// module, so the total carry-chain is twice as long as expected, plus 2 more
// bits to avoid overflow. Most of the time, this will take longer than your
// clock cycle since the carry-chain of arithmetic logic is often a limiting
// factor in timing closure.

// We can't retime a pipeline from outside since there is a loop, so we
// pipeline inside the loop here, and let that retime across the carry-chains.
// The price to pay is a latency of EXTRA_PIPE_STAGES+1 cycles between an
// increment, load, or clear, and the corresponding "done" signal.  This
// latency is why the input pulses must be asserted *for only one cycle* when
// `EXTRA_PIPE_STAGES` is greater than zero, then wait until the command has
// completed before pulsing again, else any latter increments or loads will
// override the previous ones (since the accumulated_value will have not yet
// updated).

`default_nettype none

module Accumulator_Binary_Saturating
#(
    parameter                   EXTRA_PIPE_STAGES   = -1,
    parameter                   WORD_WIDTH          =  0,
    parameter [WORD_WIDTH-1:0]  INITIAL_VALUE       =  0
)
(
    input   wire                        clock,
    input   wire                        clock_enable,

    input   wire                        clear,
    output  wire                        clear_done,

    input   wire    [WORD_WIDTH-1:0]    increment_value,
    input   wire                        increment_valid,
    output  wire                        increment_done,

    input   wire    [WORD_WIDTH-1:0]    load_value,
    input   wire                        load_valid,
    output  wire                        load_done,

    input   wire    [WORD_WIDTH-1:0]    max_limit,
    input   wire    [WORD_WIDTH-1:0]    min_limit,

    input   wire                        carry_in,
    output  wire                        carry_out,
    output  wire    [WORD_WIDTH-1:0]    accumulated_value,
    output  wire                        at_max_limit,
    output  wire                        over_max_limit,
    output  wire                        at_min_limit,
    output  wire                        under_min_limit
);

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};

// Here, we pipeline the inputs so that all signals further down are in sync,
// and to place the register pipeline inside the loop formed by the
// Adder_Subtractor_Binary_Saturating and the output register, so we can have
// forward retiming move it into the Adder_Subtractor_Binary_Saturating logic.
// (Backwards retiming is more difficult, and not supported by Vivado
// post-synth optimizations)

    wire                    clear_pipelined;

    wire [WORD_WIDTH-1:0]   increment_value_pipelined;
    wire                    increment_valid_pipelined;

    wire [WORD_WIDTH-1:0]   load_value_pipelined;
    wire                    load_valid_pipelined;

    wire [WORD_WIDTH-1:0]   max_limit_pipelined;
    wire [WORD_WIDTH-1:0]   min_limit_pipelined;

    wire                    carry_in_pipelined;
    wire [WORD_WIDTH-1:0]   accumulated_value_pipelined;

    generate
        if (EXTRA_PIPE_STAGES == 0) begin: no_pipe
            assign clear_pipelined              = clear;
            assign increment_value_pipelined    = increment_value;
            assign increment_valid_pipelined    = increment_valid;
            assign load_value_pipelined         = load_value;
            assign load_valid_pipelined         = load_valid;
            assign max_limit_pipelined          = max_limit;
            assign min_limit_pipelined          = min_limit;
            assign carry_in_pipelined           = carry_in;
            assign accumulated_value_pipelined  = accumulated_value;
        end
        else if (EXTRA_PIPE_STAGES > 0) begin: extra_pipe

            localparam PIPELINE_WIDTH       = (WORD_WIDTH * 5) + 4;
            localparam PIPELINE_WORD_ZERO   = {PIPELINE_WIDTH{1'b0}};
            localparam PIPELINE_ZERO        = {EXTRA_PIPE_STAGES{PIPELINE_WORD_ZERO}};

            Register_Pipeline
            #(
                .WORD_WIDTH     (PIPELINE_WIDTH),
                .PIPE_DEPTH     (EXTRA_PIPE_STAGES),
                // concatenation of each stage initial/reset value
                .RESET_VALUES   (PIPELINE_ZERO)
            )
            accumulator_pipeline
            (
                .clock          (clock),
                .clock_enable   (clock_enable),
                .clear          (1'b0),
                .parallel_load  (1'b0),
                .parallel_in    (PIPELINE_ZERO),
                // verilator lint_off PINCONNECTEMPTY
                .parallel_out   (),
                // verilator lint_on  PINCONNECTEMPTY
                .pipe_in        ({max_limit,           min_limit,           increment_valid,           increment_value,           load_valid,           load_value,           carry_in,           accumulated_value,           clear}),
                .pipe_out       ({max_limit_pipelined, min_limit_pipelined, increment_valid_pipelined, increment_value_pipelined, load_valid_pipelined, load_value_pipelined, carry_in_pipelined, accumulated_value_pipelined, clear_pipelined})
            );
        end
    endgenerate

// 
// **After this point, only use the pipelined inputs.**
//

// If we are *loading* then substitute the `accumulated_value` with
// zero, and the `increment` with the `load_value`. 
// If we are *clearing* then substitute the `accumulated_value` with
// zero, and the `increment` with the `INITIAL_VALUE`. 
// Converting a load or clear to an addition to zero prevents us from loading
// a value outside the given limits, which could really upset things in the
// enclosing logic, and will set the output status bits correctly.

    reg gate_accumulated_value = 1'b0;

    always @(*) begin
        gate_accumulated_value = (load_valid_pipelined == 1'b1) || (clear_pipelined == 1'b1);
    end

    wire [WORD_WIDTH-1:0] accumulated_value_gated;

    Annuller
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .IMPLEMENTATION ("AND")
    )
    gate_accumulated
    (
        .annul          (gate_accumulated_value == 1'b1),
        .data_in        (accumulated_value_pipelined),
        .data_out       (accumulated_value_gated)
    );

    reg [WORD_WIDTH-1:0] increment_selected = WORD_ZERO;

    always @(*) begin
        increment_selected = (load_valid_pipelined == 1'b1) ? load_value_pipelined : increment_value_pipelined;
        increment_selected = (clear_pipelined      == 1'b1) ? INITIAL_VALUE        : increment_selected;
    end

// Apply the increment to the current accumulator value, or the load value to
// an accumulator value of zero, or the initial value to an accumulator value
// of zero, all with saturation.

    wire [WORD_WIDTH-1:0]   incremented_value_internal;
    wire                    carry_out_internal;
    wire                    at_max_limit_internal;
    wire                    over_max_limit_internal;
    wire                    at_min_limit_internal;
    wire                    under_min_limit_internal;

    Adder_Subtractor_Binary_Saturating
    #(
        .WORD_WIDTH     (WORD_WIDTH)
    )
    add_increment
    (
        .max_limit      (max_limit_pipelined),
        .min_limit      (min_limit_pipelined),
        .add_sub        (1'b0),                     // 0/1 -> A+B/A-B
        .carry_in       (carry_in_pipelined),
        .A_in           (accumulated_value_gated),
        .B_in           (increment_selected),
        .sum_out        (incremented_value_internal),
        .carry_out      (carry_out_internal),
        .at_max_limit   (at_max_limit_internal),
        .over_max_limit (over_max_limit_internal),
        .at_min_limit   (at_min_limit_internal),
        .under_min_limit (under_min_limit_internal)
    );

// Then, update the accumulator register and other outputs sychronized to
// it. Update the registers if load or increment or the clear pulse is valid. 

    reg enable_output  = 1'b0;

    always @(*) begin
        enable_output  = (increment_valid_pipelined == 1'b1) || (load_valid_pipelined == 1'b1) || (clear_pipelined == 1'b1);
        enable_output  = (enable_output             == 1'b1) && (clock_enable         == 1'b1);
    end

    Register
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .RESET_VALUE    (INITIAL_VALUE)
    )
    accumulator
    (
        .clock          (clock),
        .clock_enable   (enable_output),
        .clear          (1'b0),
        .data_in        (incremented_value_internal),
        .data_out       (accumulated_value)
    );

    localparam STATUS_BITS_COUNT = 5;
    localparam STATUS_BITS_ZERO  = {STATUS_BITS_COUNT{1'b0}};

    Register
    #(
        .WORD_WIDTH     (STATUS_BITS_COUNT),
        .RESET_VALUE    (STATUS_BITS_ZERO)
    )
    status_bits
    (
        .clock          (clock),
        .clock_enable   (enable_output),
        .clear          (1'b0),
        .data_in        ({carry_out_internal,  at_max_limit_internal,  over_max_limit_internal,  at_min_limit_internal,  under_min_limit_internal}),
        .data_out       ({carry_out,           at_max_limit,           over_max_limit,           at_min_limit,           under_min_limit})
    );

// Finally, output the "done" signals, which are the pipelined command pulses
// plus one register delay to synchronize them to the updated
// `accumulated_value` and related data.

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    for_clear
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (1'b0),
        .data_in        (clear_pipelined),
        .data_out       (clear_done)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    for_increment
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (1'b0),
        .data_in        (increment_valid_pipelined),
        .data_out       (increment_done)
    );

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    for_load
    (
        .clock          (clock),
        .clock_enable   (clock_enable),
        .clear          (1'b0),
        .data_in        (load_valid_pipelined),
        .data_out       (load_done)
    );

endmodule

