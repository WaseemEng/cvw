///////////////////////////////////////////
// plic_apb.sv
//
// Written: bbracker@hmc.edu 18 January 2021
// Modified: 
//
// Purpose: Platform-Level Interrupt Controller
//   Based on RISC-V spec (https://github.com/riscv/riscv-plic-spec/blob/master/riscv-plic.adoc)
//   With clarifications from ROA's existing implementation (https://roalogic.github.io/plic/docs/AHB-Lite_PLIC_Datasheet.pdf)
//   Supports only 1 target core and only a global threshold.
// 
// *** Big questions:
//  Do we detect requests as level-triggered or edge-trigged?
//  If edge-triggered, do we want to allow 1 source to be able to make a number of repeated requests?
//
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

`define N `PLIC_NUM_SRC
// number of interrupt sources
// does not include source 0, which does not connect to anything according to spec
// up to 63 sources supported; *** in the future, allow up to 1023 sources

`define C 2
// number of conexts
// hardcoded to 2 contexts for now; *** later upgrade to arbitrary (up to 15872) contexts

module plic_apb (
  input  logic             PCLK, PRESETn,
  input  logic             PSEL,
  input  logic [27:0]      PADDR, 
  input  logic [`XLEN-1:0] PWDATA,
  input  logic [`XLEN/8-1:0] PSTRB,
  input  logic             PWRITE,
  input  logic             PENABLE,
  output logic [`XLEN-1:0] PRDATA,
  output logic             PREADY,
  input  logic             UARTIntr,GPIOIntr,
    (* mark_debug = "true" *)  output logic             MExtInt, SExtInt);

  logic memwrite, memread, initTrans;
  logic [23:0] entry;
  logic [31:0] Din, Dout;

  // context-independent signals
    (* mark_debug = "true" *)  logic [`N:1]      requests;
    (* mark_debug = "true" *)  logic [`N:1][2:0] intPriority;
    (* mark_debug = "true" *)  logic [`N:1]      intInProgress, intPending, nextIntPending;
  
  // context-dependent signals
  logic [`C-1:0][2:0]       intThreshold;
    (* mark_debug = "true" *)  logic [`C-1:0][`N:1]      intEn;
  logic [`C-1:0][5:0]       intClaim; // ID's are 6 bits if we stay within 63 sources
    (* mark_debug = "true" *)  logic [`C-1:0][7:1][`N:1] irqMatrix;
  logic [`C-1:0][7:1]       priorities_with_irqs;
  logic [`C-1:0][7:1]       max_priority_with_irqs;
  logic [`C-1:0][`N:1]      irqs_at_max_priority;
  logic [`C-1:0][7:1]       threshMask;

  // =======
  // AHB I/O
  // =======

  assign memwrite = PWRITE & PENABLE & PSEL;  // only write in access phase
  assign memread  = ~PWRITE & PSEL;  // read at start of access phase.  PENABLE hasn't set up before this
  assign PREADY = 1'b1; // PLIC never takes >1 cycle to respond
  assign entry = {PADDR[23:2],2'b0};

  // account for subword read/write circuitry
  // -- Note PLIC registers are 32 bits no matter what; access them with LW SW.
  if (`XLEN == 64) begin
    assign Din    = entry[2] ? PWDATA[63:32] : PWDATA[31:0];
    assign PRDATA = entry[2] ? {Dout,32'b0}  : {32'b0,Dout};
  end else begin // 32-bit
    assign PRDATA = Dout;
    assign Din    = PWDATA[31:0];
  end

  // ==================
  // Register Interface
  // ==================
  always @(posedge PCLK,negedge PRESETn) begin
    // resetting
    if (~PRESETn) begin
      intPriority   <= #1 {`N{3'b0}};
      intEn         <= #1 {2{`N'b0}};
      intThreshold  <= #1 {2{3'b0}};
      intInProgress <= #1 `N'b0;
    // writing
    end else begin
      if (memwrite)
        casez(entry)
          24'h0000??: intPriority[entry[7:2]] <= #1 Din[2:0];
          `ifdef PLIC_NUM_SRC_LT_32 // *** switch to a generate for loop so as to deprecate PLIC_NUM_SRC_LT_32 and allow up to 1023 sources
          24'h002000: intEn[0][`N:1] <= #1 Din[`N:1];
          24'h002080: intEn[1][`N:1] <= #1 Din[`N:1];
          `endif
          `ifndef PLIC_NUM_SRC_LT_32
          24'h002000: intEn[0][31:1] <= #1 Din[31:1];
          24'h002004: intEn[0][`N:32] <= #1 Din[31:0];
          24'h002080: intEn[1][31:1] <= #1 Din[31:1];
          24'h002084: intEn[1][`N:32] <= #1 Din[31:0];
          `endif
          24'h200000: intThreshold[0] <= #1 Din[2:0];
          24'h200004: intInProgress <= #1 intInProgress & ~(`N'b1 << (Din[5:0]-1)); // lower "InProgress" to signify completion 
          24'h201000: intThreshold[1] <= #1 Din[2:0];
          24'h201004: intInProgress <= #1 intInProgress & ~(`N'b1 << (Din[5:0]-1)); // lower "InProgress" to signify completion 
        endcase
      // Read synchronously because a read can have side effect of changing intInProgress
      if (memread)
        casez(entry)
          24'h0000??: Dout <= #1 {29'b0,intPriority[entry[7:2]]};
          `ifdef PLIC_NUM_SRC_LT_32
          24'h001000: Dout <= #1 {{(31-`N){1'b0}},intPending,1'b0};
          24'h002000: Dout <= #1 {{(31-`N){1'b0}},intEn[0],1'b0};
          24'h002080: Dout <= #1 {{(31-`N){1'b0}},intEn[1],1'b0};
          `endif
          `ifndef PLIC_NUM_SRC_LT_32
          24'h001000: Dout <= #1 {intPending[31:1],1'b0};
          24'h001004: Dout <= #1 {{(63-`N){1'b0}},intPending[`N:32]};
          24'h002000: Dout <= #1 {intEn[0][31:1],1'b0};
          24'h002004: Dout <= #1 {{(63-`N){1'b0}},intEn[0][`N:32]};
          24'h002080: Dout <= #1 {intEn[0][31:1],1'b0};
          24'h002084: Dout <= #1 {{(63-`N){1'b0}},intEn[1][`N:32]};
          `endif
          24'h200000: Dout <= #1 {29'b0,intThreshold[0]};
          24'h200004: begin
            Dout <= #1 {26'b0,intClaim[0]};
            intInProgress <= #1 intInProgress | (`N'b1 << (intClaim[0]-1)); // claimed requests are currently in progress of being serviced until they are completed
          end
          24'h201000: Dout <= #1 {29'b0,intThreshold[1]};
          24'h201004: begin
            Dout <= #1 {26'b0,intClaim[1]};
            intInProgress <= #1 intInProgress | (`N'b1 << (intClaim[1]-1)); // claimed requests are currently in progress of being serviced until they are completed
          end
          default: Dout <= #1 32'h0; // invalid access
        endcase
      else Dout <= #1 32'h0;
   end
  end

  // connect sources to requests
  always_comb begin
    requests = `N'b0;
    `ifdef PLIC_GPIO_ID
      requests[`PLIC_GPIO_ID] = GPIOIntr;
    `endif
    `ifdef PLIC_UART_ID
      requests[`PLIC_UART_ID] = UARTIntr;
    `endif
  end

  // pending interrupt requests
  assign nextIntPending = (intPending | requests) & ~intInProgress; // dh changed back 7/9/22 see if Buildroot still boots.  Confirmed to boot successfully.
  //assign nextIntPending = requests; // DH: RT made this change May 2022, but it seems to be a bug to not consider intInProgress; see May 23, 2022 slack discussion
  flopr #(`N) intPendingFlop(PCLK,~PRESETn,nextIntPending,intPending);

  // context-dependent signals
  genvar ctx;
  for (ctx=0; ctx<`C; ctx++) begin
    // request matrix 
    //   priority level (rows) X source ID (columns)
    //
    //   irqMatrix[ctx][pri][src] is high if source <src>
    //   has priority level <pri> and has an "active" interrupt request
    //   ("active" meaning it is enabled in context <ctx> and is pending)
    genvar src, pri;
    for (pri=1; pri<=7; pri++) begin
      for (src=1; src<=`N; src++) begin
        assign irqMatrix[ctx][pri][src] = (intPriority[src]==pri) & intPending[src] & intEn[ctx][src];
      end
    end

    // which prority levels have one or more active requests?
    assign priorities_with_irqs[ctx][7:1] = {
      |irqMatrix[ctx][7],
      |irqMatrix[ctx][6],
      |irqMatrix[ctx][5],
      |irqMatrix[ctx][4],
      |irqMatrix[ctx][3],
      |irqMatrix[ctx][2],
      |irqMatrix[ctx][1]
    }; 

    // get the highest priority level that has active requests
    assign max_priority_with_irqs[ctx][7:1] = {
      priorities_with_irqs[ctx][7],
      priorities_with_irqs[ctx][6] & ~|priorities_with_irqs[ctx][7],
      priorities_with_irqs[ctx][5] & ~|priorities_with_irqs[ctx][7:6],
      priorities_with_irqs[ctx][4] & ~|priorities_with_irqs[ctx][7:5],
      priorities_with_irqs[ctx][3] & ~|priorities_with_irqs[ctx][7:4],
      priorities_with_irqs[ctx][2] & ~|priorities_with_irqs[ctx][7:3],
      priorities_with_irqs[ctx][1] & ~|priorities_with_irqs[ctx][7:2]
    };

    // of the sources at the highest priority level that has active requests,
    // which sources have active requests?
    assign irqs_at_max_priority[ctx][`N:1] =
      ({`N{max_priority_with_irqs[ctx][7]}} & irqMatrix[ctx][7]) |
      ({`N{max_priority_with_irqs[ctx][6]}} & irqMatrix[ctx][6]) |
      ({`N{max_priority_with_irqs[ctx][5]}} & irqMatrix[ctx][5]) |
      ({`N{max_priority_with_irqs[ctx][4]}} & irqMatrix[ctx][4]) |
      ({`N{max_priority_with_irqs[ctx][3]}} & irqMatrix[ctx][3]) |
      ({`N{max_priority_with_irqs[ctx][2]}} & irqMatrix[ctx][2]) |
      ({`N{max_priority_with_irqs[ctx][1]}} & irqMatrix[ctx][1]);

    // of the sources at the highest priority level that has active requests,
    // choose the source with the lowest source ID to be the most urgent
    // and set intClaim to the source ID of the most urgent active request
    integer k;
    always_comb begin
      intClaim[ctx] = 6'b0;
      for (k=`N; k>0; k--) begin
        if (irqs_at_max_priority[ctx][k]) intClaim[ctx] = k[5:0];
      end
    end
    
    // create threshold mask
    always_comb begin
      threshMask[ctx][7] = (intThreshold[ctx] != 7);
      threshMask[ctx][6] = (intThreshold[ctx] != 6) & threshMask[ctx][7];
      threshMask[ctx][5] = (intThreshold[ctx] != 5) & threshMask[ctx][6];
      threshMask[ctx][4] = (intThreshold[ctx] != 4) & threshMask[ctx][5];
      threshMask[ctx][3] = (intThreshold[ctx] != 3) & threshMask[ctx][4];
      threshMask[ctx][2] = (intThreshold[ctx] != 2) & threshMask[ctx][3];
      threshMask[ctx][1] = (intThreshold[ctx] != 1) & threshMask[ctx][2];
    end
  end
  // is the max priority > threshold?
  // *** would it be any better to first priority encode maxPriority into binary and then ">" with threshold?
  assign MExtInt = |(threshMask[0] & priorities_with_irqs[0]);
  assign SExtInt = |(threshMask[1] & priorities_with_irqs[1]);
endmodule
