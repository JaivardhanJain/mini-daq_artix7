library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- Unit test for daq_sampler: mocks the DRP side (drives eoc/drdy/do directly),
-- returns known 12-bit codes, and self-checks the Q5.15 sample + sample_valid.
-- No XADC IP and no analog stimulus needed.
--
-- Expected (unipolar, SHIFT=4):  sample = (code - 2048) * 16
--   2048 -> 0        4095 -> +32752     0 -> -32768
--   3072 -> +16384 (=+0.5)   1024 -> -16384 (=-0.5)
-- ============================================================================
entity tb_daq_sampler is
end tb_daq_sampler;

architecture sim of tb_daq_sampler is

    constant CLK_PERIOD : time    := 10 ns;   -- 100 MHz
    constant SHIFT_C    : natural := 4;

    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal running : boolean   := true;

    signal eoc_in       : std_logic := '0';
    signal drdy_in      : std_logic := '0';
    signal do_in        : std_logic_vector(15 downto 0) := (others => '0');
    signal den_out      : std_logic;
    signal sample       : std_logic_vector(19 downto 0);
    signal sample_valid : std_logic;

begin

    dut : entity work.daq_sampler
        generic map (BIPOLAR => false, SHIFT => SHIFT_C)
        port map (
            clk => clk, reset => reset,
            eoc_in => eoc_in, drdy_in => drdy_in, do_in => do_in,
            den_out => den_out, sample => sample, sample_valid => sample_valid
        );

    clk <= (not clk) after CLK_PERIOD/2 when running else '0';

    stim : process

        -- present a conversion result (12-bit 'code') and check the sample
        procedure sample_code(code : integer) is
            variable exp : integer;
        begin
            -- signal end-of-conversion
            eoc_in <= '1';
            wait until rising_edge(clk);
            eoc_in <= '0';

            -- wait for the DRP read strobe, then return the data with drdy
            wait until den_out = '1';
            wait until rising_edge(clk);
            do_in   <= std_logic_vector(to_unsigned(code, 12)) & "0000";  -- result in [15:4]
            drdy_in <= '1';
            wait until rising_edge(clk);
            drdy_in <= '0';
            do_in   <= (others => '0');

            -- check the converted sample
            wait until sample_valid = '1';
            exp := (code - 2048) * (2**SHIFT_C);   -- unipolar expected
            if to_integer(signed(sample)) = exp then
                report "OK   code=" & integer'image(code) &
                       "  sample=" & integer'image(to_integer(signed(sample))) severity note;
            else
                report "FAIL code=" & integer'image(code) &
                       "  sample=" & integer'image(to_integer(signed(sample))) &
                       "  expected " & integer'image(exp) severity error;
            end if;
            wait until rising_edge(clk);
        end procedure;

    begin
        reset <= '1';
        wait for 100 ns;
        reset <= '0';
        wait until rising_edge(clk);

        sample_code(2048);   -- mid-scale  ->  0
        sample_code(4095);   -- full-scale -> +32752
        sample_code(0);      -- zero       -> -32768
        sample_code(3072);   -- +0.5
        sample_code(1024);   -- -0.5
        sample_code(2560);   -- +0.25  ((2560-2048)*16 = 8192)

        report "=== daq_sampler test finished ===" severity note;
        running <= false;
        wait;
    end process;

end sim;
