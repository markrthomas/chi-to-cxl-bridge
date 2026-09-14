// -----------------------------------------------------------------------------
// chi_to_cxl_uvm_pkg -- SV UVM environment for chi_to_cxl_bridge (PLAN Phase 4).
//
// A single-package UVM env that mirrors the PyUVM tier (verification/pyuvm):
//   * chi_driver     drives CHI REQ (reads + writes); for a write it waits for
//                    the bridge DBIDResp before driving the WrData beat.
//   * cxl_responder  emulates the CXL.mem device: accepts M2S Req/RwD and returns
//                    S2M DRS(MemData)/NDR(Cmp) echoing the bridge Tag; read data
//                    carries the request address so the round trip is checkable.
//   * chi_rsp_monitor owns the CHI response accept side: records DBIDResps (for
//                    the driver) and publishes Comp / CompData to the scoreboard.
//   * chi_scoreboard round-trip identity (read -> CompData(addr), write -> Comp)
//                    + request translation (MemOpcode/addr) vs the RTL mapping.
//
// Timing tasks are forked by the test (UVM-Cookbook idiom the reference uses) so
// the drive order is explicit. Elaborates with the OSS Verilator (make lint);
// the --binary run is heavier (make run) and belongs on a big CI runner.
// -----------------------------------------------------------------------------
package chi_to_cxl_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "chi_to_cxl_bridge_defs.vh"

  localparam int unsigned RUN_CLK = 600;

  // ===========================================================================
  // sequence item
  // ===========================================================================
  class chi_req_item extends uvm_sequence_item;
    rand bit [CHI_REQ_OPCODE_W-1:0] opcode;
    rand bit [CHI_CXL_ADDR_W-1:0]   addr;
    rand bit [TXNID_W-1:0]          txnid;
    rand bit [63:0]                 data;

    `uvm_object_utils_begin(chi_req_item)
      `uvm_field_int(opcode, UVM_DEFAULT)
      `uvm_field_int(addr,   UVM_DEFAULT)
      `uvm_field_int(txnid,  UVM_DEFAULT)
      `uvm_field_int(data,   UVM_DEFAULT)
    `uvm_object_utils_end

    function new(string name = "chi_req_item");
      super.new(name);
    endfunction

    function bit is_wr();
      return is_chi_write(opcode);
    endfunction
  endclass

  // ===========================================================================
  // response monitor -- owns chi_rsp_ready / chi_comp_data_ready
  // ===========================================================================
  class chi_rsp_monitor extends uvm_component;
    virtual chi_to_cxl_if vif;
    uvm_analysis_port#(bit [TXNID_W-1:0])   comp_ap;      // write completions
    uvm_analysis_port#(bit [63:0])          compdata_ap;  // {txnid, addr_lo} of a read return
    bit [TAG_W-1:0] dbid_by_txn[bit [TXNID_W-1:0]];
    `uvm_component_utils(chi_rsp_monitor)

    function new(string name, uvm_component parent);
      super.new(name, parent);
      comp_ap     = new("comp_ap", this);
      compdata_ap = new("compdata_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual chi_to_cxl_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction

    // driver calls this to await a write's DBIDResp
    task automatic wait_dbid(input bit [TXNID_W-1:0] txnid);
      while (!dbid_by_txn.exists(txnid)) @(posedge vif.clk);
    endtask

    task automatic capture();
      bit [CHI_RSP_OPCODE_W-1:0] op;
      bit [TXNID_W-1:0]          txn;
      vif.chi_rsp_ready = 1'b1;
      vif.chi_comp_data_ready = 1'b1;
      // Sample DUT outputs AT the clock edge (pre-update): the response FIFOs are
      // first-word-fall-through and are popped this same edge (ready held high),
      // so a post-edge (#0.1) read would see the already-advanced/emptied FIFO and
      // miss the beat. Reading at the edge captures the beat being consumed.
      fork
        forever begin
          @(posedge vif.clk);
          if (vif.chi_rsp_valid && vif.chi_rsp_ready) begin
            op  = vif.chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W];
            txn = vif.chi_rsp_data[CHI_RSP_TXNID_LSB  +: TXNID_W];
            if (op == CHI_RSP_DBIDRESP)
              dbid_by_txn[txn] = vif.chi_rsp_data[CHI_RSP_DBID_LSB +: TAG_W];
            else if (op == CHI_RSP_COMP)
              comp_ap.write(txn);
          end
        end
        forever begin
          @(posedge vif.clk);
          if (vif.chi_comp_data_valid && vif.chi_comp_data_ready)
            // pack {8'b0, txnid[7:0], addr_lo[47:0]}
            compdata_ap.write({8'b0,
                               vif.chi_comp_data[CHI_DAT_TXNID_LSB +: TXNID_W],
                               vif.chi_comp_data[CHI_DAT_DATA_LSB  +: 48]});
        end
      join
    endtask
  endclass

  // ===========================================================================
  // CHI driver
  // ===========================================================================
  class chi_driver extends uvm_driver#(chi_req_item);
    virtual chi_to_cxl_if vif;
    chi_rsp_monitor       rsp_mon;
    uvm_analysis_port#(chi_req_item) drv_ap;
    `uvm_component_utils(chi_driver)

    function new(string name, uvm_component parent);
      super.new(name, parent);
      drv_ap = new("drv_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual chi_to_cxl_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction

    task automatic drive();
      vif.chi_req_valid = 1'b0;
      vif.chi_wr_data_valid = 1'b0;
      forever begin
        chi_req_item it;
        seq_item_port.get_next_item(it);
        // drive the request
        #0.1;
        vif.chi_req_data  = '0;
        vif.chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = it.opcode;
        vif.chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = it.addr;
        vif.chi_req_data[CHI_REQ_TXNID_LSB  +: TXNID_W]          = it.txnid;
        vif.chi_req_valid = 1'b1;
        do begin @(posedge vif.clk); #0.1; end while (!vif.chi_req_ready);
        vif.chi_req_valid = 1'b0;
        if (it.is_wr()) begin
          rsp_mon.wait_dbid(it.txnid);
          #0.1;
          vif.chi_wr_data = '0;
          vif.chi_wr_data[CHI_DAT_DATA_LSB +: 64] = it.data;
          vif.chi_wr_data[CHI_DAT_BE_LSB   +: CHI_DAT_BE_W] = {CHI_DAT_BE_W{1'b1}};
          vif.chi_wr_data_valid = 1'b1;
          do begin @(posedge vif.clk); #0.1; end while (!vif.chi_wr_data_ready);
          vif.chi_wr_data_valid = 1'b0;
        end
        drv_ap.write(it);
        seq_item_port.item_done();
      end
    endtask
  endclass

  // ===========================================================================
  // sequencer + sequences
  // ===========================================================================
  typedef uvm_sequencer#(chi_req_item) chi_sequencer;

  class roundtrip_seq extends uvm_sequence#(chi_req_item);
    `uvm_object_utils(roundtrip_seq)
    function new(string name = "roundtrip_seq");
      super.new(name);
    endfunction

    task send(input bit [6:0] op, input bit [47:0] addr, input bit [7:0] txn,
              input bit [63:0] data = 64'h0);
      chi_req_item it = chi_req_item::type_id::create("it");
      it.opcode = op; it.addr = addr; it.txnid = txn; it.data = data;
      start_item(it);
      finish_item(it);
    endtask

    task body();
      // reads (both opcodes), then writes (all three), then more reads
      send(CHI_REQ_READNOSNP, 48'hC0DE_0000, 8'h10);
      send(CHI_REQ_READONCE,  48'hC0DE_0040, 8'h11);
      send(CHI_REQ_READNOSNP, 48'hC0DE_0080, 8'h12);
      send(CHI_REQ_WRITENOSNPFULL,  48'hDEAD_0000, 8'h40, 64'h1111_2222_3333_4444);
      send(CHI_REQ_WRITENOSNPPTL,   48'hDEAD_0040, 8'h41, 64'h5555_6666_7777_8888);
      send(CHI_REQ_WRITEUNIQUEFULL, 48'hDEAD_0080, 8'h42, 64'h9999_AAAA_BBBB_CCCC);
      send(CHI_REQ_READONCE,  48'hC0DE_00C0, 8'h13);
    endtask
  endclass

  // ===========================================================================
  // CXL responder -- accepts M2S, returns S2M
  // ===========================================================================
  class cxl_responder extends uvm_component;
    virtual chi_to_cxl_if vif;
    uvm_analysis_port#(bit [63:0]) m2s_req_ap;  // {memop, addr_lo}
    uvm_analysis_port#(bit [63:0]) m2s_rwd_ap;  // {memop, addr_lo}
    bit [TAG_W-1:0] drs_tag_q[$];
    bit [47:0]      drs_addr_q[$];
    bit [TAG_W-1:0] ndr_tag_q[$];
    `uvm_component_utils(cxl_responder)

    function new(string name, uvm_component parent);
      super.new(name, parent);
      m2s_req_ap = new("m2s_req_ap", this);
      m2s_rwd_ap = new("m2s_rwd_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual chi_to_cxl_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction

    task automatic accept();
      bit [TAG_W-1:0] tag;
      bit [47:0]      raddr, waddr;
      vif.cxl_tx_req_ready = 1'b1;
      vif.cxl_tx_rwd_ready = 1'b1;
      // Sample AT the edge (pre-update): the M2S FIFOs are FWFT and pop this same
      // edge (ready held high), so a post-edge read would see the next flit.
      forever begin
        @(posedge vif.cxl_clk);
        if (vif.cxl_tx_req_valid && vif.cxl_tx_req_ready) begin
          tag   = vif.cxl_tx_req_data[CXL_REQ_TAG_LSB  +: TAG_W];
          raddr = vif.cxl_tx_req_data[CXL_REQ_ADDR_LSB +: CXL_REQ_ADDR_W];
          // pack {12'b0, memop[3:0], addr[47:0]}
          m2s_req_ap.write({12'b0, vif.cxl_tx_req_data[CXL_REQ_MEMOP_LSB +: CXL_REQ_MEMOP_W], raddr});
          drs_tag_q.push_back(tag);
          drs_addr_q.push_back(raddr);
        end
        if (vif.cxl_tx_rwd_valid && vif.cxl_tx_rwd_ready) begin
          waddr = vif.cxl_tx_rwd_data[CXL_RWD_ADDR_LSB +: CXL_RWD_ADDR_W];
          m2s_rwd_ap.write({12'b0, vif.cxl_tx_rwd_data[CXL_RWD_MEMOP_LSB +: CXL_RWD_MEMOP_W], waddr});
          ndr_tag_q.push_back(vif.cxl_tx_rwd_data[CXL_RWD_TAG_LSB +: TAG_W]);
        end
      end
    endtask

    task automatic respond();
      vif.cxl_rx_drs_valid = 1'b0;
      vif.cxl_rx_ndr_valid = 1'b0;
      fork
        forever begin
          @(posedge vif.cxl_clk); #0.1;
          if (drs_tag_q.size() != 0 && !vif.cxl_rx_drs_valid) begin
            vif.cxl_rx_drs_data = '0;
            vif.cxl_rx_drs_data[CXL_DRS_OPCODE_LSB +: CXL_DRS_OPCODE_W] = CXL_DRS_MEMDATA;
            vif.cxl_rx_drs_data[CXL_DRS_TAG_LSB    +: CXL_DRS_TAG_W]    = drs_tag_q[0];
            vif.cxl_rx_drs_data[CXL_DRS_DATA_LSB   +: 48]              = drs_addr_q[0];
            vif.cxl_rx_drs_valid = 1'b1;
          end
          if (vif.cxl_rx_drs_valid && vif.cxl_rx_drs_ready) begin
            void'(drs_tag_q.pop_front()); void'(drs_addr_q.pop_front());
            vif.cxl_rx_drs_valid = 1'b0;
          end
        end
        forever begin
          @(posedge vif.cxl_clk); #0.1;
          if (ndr_tag_q.size() != 0 && !vif.cxl_rx_ndr_valid) begin
            vif.cxl_rx_ndr_data = '0;
            vif.cxl_rx_ndr_data[CXL_NDR_OPCODE_LSB +: CXL_NDR_OPCODE_W] = CXL_NDR_CMP;
            vif.cxl_rx_ndr_data[CXL_NDR_TAG_LSB    +: CXL_NDR_TAG_W]    = ndr_tag_q[0];
            vif.cxl_rx_ndr_valid = 1'b1;
          end
          if (vif.cxl_rx_ndr_valid && vif.cxl_rx_ndr_ready) begin
            void'(ndr_tag_q.pop_front());
            vif.cxl_rx_ndr_valid = 1'b0;
          end
        end
      join
    endtask
  endclass

  // ===========================================================================
  // scoreboard
  // ===========================================================================
  `uvm_analysis_imp_decl(_drv)
  `uvm_analysis_imp_decl(_mreq)
  `uvm_analysis_imp_decl(_mrwd)
  `uvm_analysis_imp_decl(_comp)
  `uvm_analysis_imp_decl(_cdata)

  class chi_scoreboard extends uvm_scoreboard;
    uvm_analysis_imp_drv  #(chi_req_item,   chi_scoreboard) drv_ap;
    uvm_analysis_imp_mreq #(bit [63:0],     chi_scoreboard) mreq_ap;
    uvm_analysis_imp_mrwd #(bit [63:0],     chi_scoreboard) mrwd_ap;
    uvm_analysis_imp_comp #(bit [TXNID_W-1:0], chi_scoreboard) comp_ap;
    uvm_analysis_imp_cdata#(bit [63:0],     chi_scoreboard) cdata_ap;

    chi_req_item driven_q[$];
    bit [63:0]   mreq_q[$];
    bit [63:0]   mrwd_q[$];
    bit          comp_seen[bit [TXNID_W-1:0]];
    bit [47:0]   cdata_addr_by_txn[bit [TXNID_W-1:0]];
    int          errors;
    `uvm_component_utils(chi_scoreboard)

    function new(string name, uvm_component parent);
      super.new(name, parent);
      drv_ap   = new("drv_ap", this);
      mreq_ap  = new("mreq_ap", this);
      mrwd_ap  = new("mrwd_ap", this);
      comp_ap  = new("comp_ap", this);
      cdata_ap = new("cdata_ap", this);
    endfunction

    function void write_drv (chi_req_item it);   driven_q.push_back(it); endfunction
    function void write_mreq(bit [63:0] v);      mreq_q.push_back(v);    endfunction
    function void write_mrwd(bit [63:0] v);      mrwd_q.push_back(v);    endfunction
    function void write_comp(bit [TXNID_W-1:0] t); comp_seen[t] = 1'b1;  endfunction
    function void write_cdata(bit [63:0] v);
      // v = {8'b0, txnid[7:0], addr_lo[47:0]}
      cdata_addr_by_txn[v[55:48]] = v[47:0];
    endfunction

    function int exp_req_memop(bit [6:0] op);
      if (op == CHI_REQ_READNOSNP) return CXL_MEMRD;
      if (op == CHI_REQ_READONCE)  return CXL_MEMRDDATA;
      return CXL_MEMINV;
    endfunction

    function void check_phase(uvm_phase phase);
      int ri = 0, wi = 0;
      foreach (driven_q[i]) begin
        chi_req_item it = driven_q[i];
        if (it.is_wr()) begin
          bit [63:0] mw;
          int exp_memop = (it.opcode == CHI_REQ_WRITENOSNPPTL) ? CXL_MEMWRPTL : CXL_MEMWR;
          if (wi >= mrwd_q.size()) begin errors++;
            `uvm_error("SB", $sformatf("write #%0d: no M2S RwD", wi)) end
          else begin
            mw = mrwd_q[wi];
            if (mw[47:0] !== it.addr) begin errors++;
              `uvm_error("SB", $sformatf("write #%0d addr %h != %h", wi, mw[47:0], it.addr)) end
            if (int'(mw[51:48]) !== exp_memop) begin errors++;
              `uvm_error("SB", $sformatf("write #%0d memop %0d != %0d", wi, mw[51:48], exp_memop)) end
          end
          if (!comp_seen.exists(it.txnid)) begin errors++;
            `uvm_error("SB", $sformatf("write txnid %h: no Comp", it.txnid)) end
          wi++;
        end else begin
          bit [63:0] mr;
          if (ri >= mreq_q.size()) begin errors++;
            `uvm_error("SB", $sformatf("read #%0d: no M2S Req", ri)) end
          else begin
            mr = mreq_q[ri];
            if (mr[47:0] !== it.addr) begin errors++;
              `uvm_error("SB", $sformatf("read #%0d addr %h != %h", ri, mr[47:0], it.addr)) end
            if (int'(mr[51:48]) !== exp_req_memop(it.opcode)) begin errors++;
              `uvm_error("SB", $sformatf("read #%0d memop %0d != %0d", ri, mr[51:48], exp_req_memop(it.opcode))) end
          end
          if (!cdata_addr_by_txn.exists(it.txnid)) begin errors++;
            `uvm_error("SB", $sformatf("read txnid %h: no CompData", it.txnid)) end
          else if (cdata_addr_by_txn[it.txnid] !== it.addr) begin errors++;
            `uvm_error("SB", $sformatf("read txnid %h: CompData addr %h != %h",
                       it.txnid, cdata_addr_by_txn[it.txnid], it.addr)) end
          ri++;
        end
      end
      if (errors == 0)
        `uvm_info("SB", $sformatf("PASS: %0d requests round-trip + translation OK",
                  driven_q.size()), UVM_LOW)
    endfunction
  endclass

  // ===========================================================================
  // env
  // ===========================================================================
  class chi_env extends uvm_env;
    chi_sequencer   seqr;
    chi_driver      driver;
    chi_rsp_monitor rsp_mon;
    cxl_responder   responder;
    chi_scoreboard  sb;
    `uvm_component_utils(chi_env)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      seqr      = chi_sequencer::type_id::create("seqr", this);
      driver    = chi_driver::type_id::create("driver", this);
      rsp_mon   = chi_rsp_monitor::type_id::create("rsp_mon", this);
      responder = cxl_responder::type_id::create("responder", this);
      sb        = chi_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      driver.seq_item_port.connect(seqr.seq_item_export);
      driver.rsp_mon = rsp_mon;
      driver.drv_ap.connect(sb.drv_ap);
      responder.m2s_req_ap.connect(sb.mreq_ap);
      responder.m2s_rwd_ap.connect(sb.mrwd_ap);
      rsp_mon.comp_ap.connect(sb.comp_ap);
      rsp_mon.compdata_ap.connect(sb.cdata_ap);
    endfunction
  endclass

  // ===========================================================================
  // test
  // ===========================================================================
  class chi_roundtrip_test extends uvm_test;
    chi_env               env;
    virtual chi_to_cxl_if vif;
    `uvm_component_utils(chi_roundtrip_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual chi_to_cxl_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
      env = chi_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      roundtrip_seq seq;
      phase.raise_objection(this);
      // idle inputs
      vif.chi_req_valid = 0; vif.chi_req_data = '0;
      vif.chi_wr_data_valid = 0; vif.chi_wr_data = '0;
      vif.chi_snp_valid = 0; vif.chi_snp_data = '0; vif.chi_snp_resp_ready = 1;
      vif.err_inj_en = 0;
      wait (vif.rst_n === 1'b1);
      repeat (4) @(posedge vif.clk);

      fork
        env.rsp_mon.capture();
        env.responder.accept();
        env.responder.respond();
        env.driver.drive();
      join_none

      seq = roundtrip_seq::type_id::create("seq");
      seq.start(env.seqr);

      repeat (RUN_CLK) @(posedge vif.clk);
      phase.drop_objection(this);
    endtask
  endclass

endpackage : chi_to_cxl_uvm_pkg
