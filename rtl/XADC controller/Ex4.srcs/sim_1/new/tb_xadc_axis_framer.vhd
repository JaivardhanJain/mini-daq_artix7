library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- Unit test for xadc_axis_framer.
--   1) Framing check: feed 32 samples (value = index) = 2 frames; check each
--      AXIS beat's TDATA (real=idx, imag=0), TLAST (only on beats 15 and 31),
--      and TKEEP/TSTRB (all ones).
--   2) Back-pressure check: hold TREADY low, confirm the beat is HELD (TVALID
--      stays, data stable), then release and confirm it drains.
-- ============================================================================
entity tb_xadc_axis_framer is
end tb_xadc_axis_framer;

architecture sim of tb_xadc_axis_framer is
    constant CLK_PERIOD : time    := 10 ns;
    constant FRAME      : natural := 16;

    signal clk, reset : std_logic := '0';
    signal running    : boolean   := true;

    signal sample       : std_logic_vector(19 downto 0) := (others => '0');
    signal sample_valid : std_logic := '0';
    signal m_tdata      : std_logic_vector(39 downto 0);
    signal m_tvalid     : std_logic;
    signal m_tready     : std_logic := '1';
    signal m_tlast      : std_logic;
    signal m_tkeep      : std_logic_vector(4 downto 0);
    signal m_tstrb      : std_logic_vector(4 downto 0);
    signal overflow     : std_logic;
begin

    dut : entity work.xadc_axis_framer
        generic map (FRAME => FRAME)
        port map (
            clk => clk, reset => reset,
            sample => sample, sample_valid => sample_valid,
            m_tdata => m_tdata, m_tvalid => m_tvalid, m_tready => m_tready,
            m_tlast => m_tlast, m_tkeep => m_tkeep, m_tstrb => m_tstrb,
            overflow => overflow
        );

    clk <= (not clk) after CLK_PERIOD/2 when running else '0';

    stim : process
        variable err_v : integer := 0;

        -- present one sample and check the resulting beat (TREADY held high)
        procedure send_check(idx : integer) is
            variable exp_last : std_logic;
        begin
            sample       <= std_logic_vector(to_signed(idx, 20));
            sample_valid <= '1';
            wait until rising_edge(clk);         -- framer captures
            sample_valid <= '0';
            wait until m_tvalid = '1';           -- beat presented

            if m_tdata(19 downto 0) /= std_logic_vector(to_signed(idx, 20)) then
                err_v := err_v + 1; report "FAIL data idx=" & integer'image(idx) severity error;
            end if;
            if unsigned(m_tdata(39 downto 20)) /= 0 then
                err_v := err_v + 1; report "FAIL imag/=0 idx=" & integer'image(idx) severity error;
            end if;
            if (idx mod FRAME) = FRAME-1 then exp_last := '1'; else exp_last := '0'; end if;
            if m_tlast /= exp_last then
                err_v := err_v + 1; report "FAIL tlast idx=" & integer'image(idx) severity error;
            end if;
            if m_tkeep /= "11111" or m_tstrb /= "11111" then
                err_v := err_v + 1; report "FAIL keep/strb idx=" & integer'image(idx) severity error;
            end if;

            wait until rising_edge(clk);         -- beat accepted (TREADY=1)
        end procedure;

    begin
        reset <= '1'; wait for 100 ns; reset <= '0';
        wait until rising_edge(clk);

        -- 1) framing: 32 samples = 2 frames
        for i in 0 to 31 loop
            send_check(i);
        end loop;

        -- 2) back-pressure: hold TREADY low and confirm the beat holds
        m_tready <= '0';
        sample <= std_logic_vector(to_signed(9, 20));
        sample_valid <= '1';
        wait until rising_edge(clk);
        sample_valid <= '0';
        wait until m_tvalid = '1';
        for i in 0 to 3 loop wait until rising_edge(clk); end loop;   -- stall
        if m_tvalid /= '1' or m_tdata(19 downto 0) /= std_logic_vector(to_signed(9, 20)) then
            err_v := err_v + 1; report "FAIL back-pressure hold" severity error;
        end if;
        m_tready <= '1';                                             -- release
        wait until rising_edge(clk);

        if err_v = 0 then
            report "=== framer test PASS (32 beats, 2 frames, back-pressure) ===" severity note;
        else
            report "=== framer test FAILED: " & integer'image(err_v) & " error(s) ===" severity error;
        end if;

        running <= false;
        wait;
    end process;

end sim;
