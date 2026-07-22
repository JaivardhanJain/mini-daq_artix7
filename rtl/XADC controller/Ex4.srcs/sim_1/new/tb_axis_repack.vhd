library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- tb_axis_repack : self-checking unit test for axis_repack (N=16).
--
--   Frame 1 (happy path): stream SIZE beats with m_tready held high; check
--     * exactly SIZE/2+1 (=9) output words appear, for bins 0..8
--     * each packed word = {real[19:4], imag[19:4]} (Q5.11 truncation)
--     * m_tlast asserted only on the 9th word (bin 8)
--     * bins 9..15 are consumed but produce NO output word
--
--   Frame 2 (back-pressure): same stream, but on a KEPT bin (4) the FIFO drops
--   m_tready for a few cycles. While stalled we assert the block HOLDS the beat:
--     * s_tready goes low (back-pressure passed upstream to fft_axis)
--     * m_tvalid stays high and m_tdata stays stable (nothing lost/changed)
--   then m_tready returns and the beat transfers -- the frame still yields 9
--   correct words. Proves the s_tready mux, the one branch frame 1 can't reach.
--
--   The checker is frame-aware: its expected bin index resets on m_tlast, so it
--   validates both frames; words_seen totals across them.
-- ============================================================================
entity tb_axis_repack is
end tb_axis_repack;

architecture sim of tb_axis_repack is

    constant SIZE     : natural := 16;
    constant FRAMES   : natural := 2;
    constant CLK_PER  : time    := 10 ns;            -- 100 MHz

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';

    signal s_tdata  : std_logic_vector(39 downto 0) := (others => '0');
    signal s_tvalid : std_logic := '0';
    signal s_tready : std_logic;
    signal s_tlast  : std_logic := '0';

    signal m_tdata  : std_logic_vector(31 downto 0);
    signal m_tvalid : std_logic;
    signal m_tready : std_logic := '1';              -- FIFO ready; pulled low in frame 2
    signal m_tlast  : std_logic;
    signal m_tkeep  : std_logic_vector(3 downto 0);
    signal m_tstrb  : std_logic_vector(3 downto 0);

    -- total output words the checker has accepted across all frames.
    signal words_seen : integer := 0;

    -- set true when the test is over; stops the clock so 'run -all' ends cleanly.
    signal sim_done : boolean := false;

    -- Build a 40-bit beat for bin k with distinct, recognizable real/imag so
    -- truncation and ordering are visible. Real ~ +k, imag ~ -k in Q5.15, each
    -- with a nonzero low nibble so the <<4 truncation is observable.
    function make_beat(k : integer) return std_logic_vector is
        variable re : signed(19 downto 0);
        variable im : signed(19 downto 0);
        variable b  : std_logic_vector(39 downto 0);
    begin
        re := to_signed(k * 2**15 + 5, 20);          -- real ~ k.000..., +5 LSBs
        im := to_signed(-(k * 2**15) - 3, 20);       -- imag ~ -k.000..., -3 LSBs
        b(19 downto 0)  := std_logic_vector(re);
        b(39 downto 20) := std_logic_vector(im);
        return b;
    end function;

    -- expected packed output word for bin k (Q5.11 real:imag).
    function expect_word(k : integer) return std_logic_vector is
        variable b : std_logic_vector(39 downto 0) := make_beat(k);
    begin
        return b(19 downto 4) & b(39 downto 24);
    end function;

begin

    clk <= not clk after CLK_PER/2 when not sim_done else '0';   -- stops at end of test

    dut : entity work.axis_repack
        generic map ( SIZE => SIZE )
        port map (
            clk => clk, reset => reset,
            s_tdata => s_tdata, s_tvalid => s_tvalid, s_tready => s_tready, s_tlast => s_tlast,
            m_tdata => m_tdata, m_tvalid => m_tvalid, m_tready => m_tready, m_tlast => m_tlast,
            m_tkeep => m_tkeep, m_tstrb => m_tstrb
        );

    -- ---- stimulus ----------------------------------------------------------
    stim : process
        -- Send one beat, honoring s_tready. If stall>0, first hold m_tready low
        -- for 'stall' cycles (only meaningful on a KEPT bin) and assert the beat
        -- is held, then release and let it transfer.
        procedure send_beat(k : integer; last : std_logic; stall : integer) is
        begin
            s_tdata  <= make_beat(k);
            s_tvalid <= '1';
            s_tlast  <= last;

            if stall > 0 then
                m_tready <= '0';                     -- FIFO refuses this beat
                for i in 1 to stall loop
                    wait until rising_edge(clk);
                    assert s_tready = '0'
                        report "back-pressure: s_tready must be low while FIFO not ready (bin "
                               & integer'image(k) & ")" severity error;
                    assert m_tvalid = '1'
                        report "back-pressure: m_tvalid must stay high while stalled (bin "
                               & integer'image(k) & ")" severity error;
                    assert m_tdata = expect_word(k)
                        report "back-pressure: m_tdata must be held stable while stalled (bin "
                               & integer'image(k) & ")" severity error;
                end loop;
                m_tready <= '1';                     -- FIFO accepts again
            end if;

            loop
                wait until rising_edge(clk);
                exit when s_tready = '1';
            end loop;
        end procedure;

        -- stream one full SIZE-beat frame; stall_bin<0 means no stall.
        procedure send_frame(stall_bin : integer) is
        begin
            for k in 0 to SIZE-1 loop
                if k = SIZE-1 then
                    send_beat(k, '1', 0);            -- TLAST on the final bin
                elsif k = stall_bin then
                    send_beat(k, '0', 3);            -- back-pressure here
                else
                    send_beat(k, '0', 0);
                end if;
            end loop;
            s_tvalid <= '0'; s_tlast <= '0';
        end procedure;
    begin
        reset <= '1'; wait for 4*CLK_PER; wait until rising_edge(clk);
        reset <= '0';

        send_frame(-1);                              -- frame 1: happy path
        wait for 4*CLK_PER;
        send_frame(4);                               -- frame 2: stall kept bin 4
        wait for 10*CLK_PER;                         -- let the last words drain

        assert words_seen = FRAMES * (SIZE/2 + 1)
            report "axis_repack: wrong total word count, got " & integer'image(words_seen)
                   & " expected " & integer'image(FRAMES * (SIZE/2 + 1))
            severity error;

        report "=== tb_axis_repack finished: " & integer'image(words_seen)
               & " words checked over " & integer'image(FRAMES) & " frames ===" severity note;
        sim_done <= true;                            -- stop the clock -> run -all ends
        wait;
    end process;

    -- ---- monitor/checker: verify every accepted output word ----------------
    check : process
        variable k : integer := 0;                   -- expected bin index within the current frame
    begin
        wait until rising_edge(clk);
        if reset = '0' and m_tvalid = '1' and m_tready = '1' then
            -- 1. never more unique bins than SIZE/2 (0..8 => 9 words per frame).
            assert k <= SIZE/2
                report "axis_repack: too many words in a frame (a redundant bin was not dropped)"
                severity error;

            -- 2. packed word must equal the truncated {real[19:4], imag[19:4]}.
            assert m_tdata = expect_word(k)
                report "axis_repack: TDATA mismatch at bin " & integer'image(k)
                severity error;

            -- 3. TLAST high exactly on the last unique bin (SIZE/2), low elsewhere.
            assert (m_tlast = '1') = (k = SIZE/2)
                report "axis_repack: TLAST misplaced at bin " & integer'image(k)
                severity error;

            words_seen <= words_seen + 1;
            if m_tlast = '1' then
                k := 0;                              -- frame boundary -> next frame
            else
                k := k + 1;
            end if;
        end if;
    end process;

end sim;
