library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- axis_repack : fft_axis 40-bit beats -> 32-bit CPU words, unique bins only.
--
--   Sits between fft_axis (master) and the AXI4-Stream FIFO (axi_fifo_mm_s).
--   For each 40-bit input beat (one FFT bin, streamed in natural order 0..N-1):
--       in  s_tdata(19 downto 0)  = real  (Q5.15)
--       in  s_tdata(39 downto 20) = imag  (Q5.15)
--   it truncates each value 20->16 bits by DROPPING THE LOW 4 (=> Q5.11,
--   range preserved, sign bit kept) and packs both into one 32-bit word:
--       out m_tdata(31 downto 16) = real[19:4]   (Q5.11)
--       out m_tdata(15 downto  0) = imag[19:4]   (Q5.11)
--
--   Only the N/2+1 UNIQUE bins (0 .. N/2) are forwarded; a real input gives a
--   conjugate-symmetric spectrum, so bins N/2+1 .. N-1 are redundant and are
--   CONSUMED-AND-DISCARDED (not stalled). m_tlast is asserted on bin N/2.
--
--   Two rules that keep this correct against a free-running fft_axis:
--     (1) DROPPED beats are always accepted (s_tready held high) so the source
--         never stalls on a bin we don't want.
--     (2) KEPT beats propagate the downstream FIFO's back-pressure (s_tready
--         follows m_tready), so a full FIFO holds the bin instead of losing it.
--
--   SIZE generic = FFT N (16 now, 256 later). Must equal the framer FRAME and
--   the FFT SIZE. Everything below is parameterized so bumping N is config.
-- ============================================================================
entity axis_repack is
    generic (
        SIZE : natural := 16                       -- FFT N; unique bins = SIZE/2 + 1
    );
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;                 -- active high
        -- AXI4-Stream slave  <- fft_axis
        s_tdata   : in  std_logic_vector(39 downto 0);
        s_tvalid  : in  std_logic;
        s_tready  : out std_logic;
        s_tlast   : in  std_logic;
        -- AXI4-Stream master -> axi_fifo_mm_s
        m_tdata   : out std_logic_vector(31 downto 0);
        m_tvalid  : out std_logic;
        m_tready  : in  std_logic;
        m_tlast   : out std_logic;
        m_tkeep   : out std_logic_vector(3 downto 0);
        m_tstrb   : out std_logic_vector(3 downto 0)
    );
end axis_repack;

architecture Behavioral of axis_repack is

    -- Index of the input beat currently on the bus = the FFT bin number (0..SIZE-1).
    signal bin  : integer range 0 to SIZE-1 := 0;

    -- Convenience: does the CURRENT beat belong to a bin we forward?  (bin <= SIZE/2)
    signal keep : std_logic;

    -- A beat is "accepted" (consumed off the input) when it is valid AND we are
    -- ready for it. Handy to have as one signal for the counter below.
    signal beat_accepted : std_logic;

begin

    -- ------------------------------------------------------------------------
    -- (1) COMBINATIONAL: keep?  This one is a freebie to anchor the rest.
    -- ------------------------------------------------------------------------
    keep <= '1' when bin <= SIZE/2 else '0';

    -- ------------------------------------------------------------------------
    -- (2) COMBINATIONAL: the AXI-Stream handshakes and the packed data.
    --     TODO(JJ) — fill these four. The reasoning is in the header banner.
    --
    --   s_tready  : accept EVERY beat we mean to drop; for kept beats, follow
    --               m_tready. Hint: it's a one-line mux on 'keep'.
    --   m_tvalid  : present a word downstream only for kept beats that are valid.
    --   m_tdata   : pack real[19:4] into the high half, imag[19:4] into the low
    --               half. Imag lives in s_tdata(39 downto 20), so imag[19:4] is
    --               s_tdata(39 downto 24); real[19:4] is s_tdata(19 downto 4).
    --   m_tlast   : assert on the LAST unique bin (bin = SIZE/2) when valid.
    -- ------------------------------------------------------------------------
    -- (1) accept EVERY dropped beat (keep='0' -> ready always); for a KEPT beat,
    --     pass the FIFO's back-pressure straight through (ready follows m_tready).
    s_tready <= m_tready when keep = '1' else '1';

    -- (2) present a word downstream only for a kept, valid beat.
    m_tvalid <= s_tvalid and keep;

    -- (3) pack: real[19:4] in the high half, imag[19:4] in the low half (Q5.11 each).
    --     imag lives in s_tdata(39 downto 20), so imag[19:4] = s_tdata(39 downto 24).
    m_tdata  <= s_tdata(19 downto 4) & s_tdata(39 downto 24);

    -- (4) end-of-frame on the last unique bin (SIZE/2), qualified by valid.
    m_tlast  <= '1' when (bin = SIZE/2 and s_tvalid = '1') else '0';

    -- Whole 32-bit word is always meaningful, so keep/strb are all-ones.
    m_tkeep  <= (others => '1');
    m_tstrb  <= (others => '1');

    -- beat_accepted = valid AND ready. Ready is (dropped) or (kept and FIFO ready),
    -- i.e. exactly the s_tready condition -- written out directly here so we don't
    -- have to read back the 'out' port s_tready.
    beat_accepted <= '1' when (s_tvalid = '1' and (keep = '0' or m_tready = '1')) else '0';

    -- ------------------------------------------------------------------------
    -- (3) SEQUENTIAL: advance the bin counter, resync on input TLAST.
    --     TODO(JJ): on each accepted beat, increment bin; when the beat carries
    --     s_tlast (fft_axis marks bin SIZE-1) OR bin already = SIZE-1, wrap to 0.
    --     Resyncing off s_tlast (not just the count) means a glitch can't leave
    --     the bin alignment permanently shifted.
    -- ------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bin <= 0;
            else
                if beat_accepted = '1' then
                    if s_tlast = '1' or bin = SIZE-1 then
                        bin <= 0;                     -- resync on the frame boundary
                    else
                        bin <= bin + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;
