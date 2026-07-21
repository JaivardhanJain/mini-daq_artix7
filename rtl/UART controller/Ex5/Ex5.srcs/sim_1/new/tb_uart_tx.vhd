library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_uart_tx is
end tb_uart_tx;

architecture sim of tb_uart_tx is

    constant CLK_PERIOD : time := 10 ns;     -- 100 MHz
    constant BIT_PERIOD : time := 8680 ns;   -- 868 cycles @ 10 ns = 115200 baud

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal tx_start : std_logic := '0';
    signal data_in  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx       : std_logic;
    signal tx_busy  : std_logic;

    signal running  : boolean := true;

    -- VHDL-93-compatible hex printer
    function hex2(v : std_logic_vector(7 downto 0)) return string is
        constant hc : string(1 to 16) := "0123456789ABCDEF";
        variable s  : string(1 to 2);
    begin
        s(1) := hc(to_integer(unsigned(v(7 downto 4))) + 1);
        s(2) := hc(to_integer(unsigned(v(3 downto 0))) + 1);
        return s;
    end function;

begin

    ------------------------------------------------------------------
    -- Device under test
    ------------------------------------------------------------------
    dut : entity work.uart_tx
        port map (
            clk      => clk,
            reset    => reset,
            tx_start => tx_start,
            data_in  => data_in,
            tx       => tx,
            tx_busy  => tx_busy
        );

    -- gated 100 MHz clock (stops when 'running' goes false)
    clk <= (not clk) after CLK_PERIOD / 2 when running else '0';

    ------------------------------------------------------------------
    -- Stimulus: reset, then send one byte (0x53 = 'S')
    ------------------------------------------------------------------
    stim : process
    begin
        reset    <= '1';
        tx_start <= '0';
        data_in  <= (others => '0');
        wait for 100 ns;
        reset <= '0';
        wait for 50 ns;

        data_in  <= x"53";                 -- the byte to send
        tx_start <= '1';
        wait until rising_edge(clk);       -- one-clock start pulse
        tx_start <= '0';

        wait for 120 us;                   -- let the whole frame go out
        report "=== Simulation finished ===" severity note;
        running <= false;
        wait;
    end process;

    ------------------------------------------------------------------
    -- Monitor: decode the tx line the way a real receiver would
    --   (find start bit, sample mid-bit, 8 bits LSB first, check stop)
    ------------------------------------------------------------------
    monitor : process
        variable b : std_logic_vector(7 downto 0);
    begin
        wait until tx = '0';                    -- falling edge = start bit
        wait for BIT_PERIOD + BIT_PERIOD / 2;   -- move to the middle of data bit 0
        for i in 0 to 7 loop
            b(i) := tx;                         -- LSB first
            wait for BIT_PERIOD;
        end loop;
        -- now near the middle of the stop bit
        report "TX decoded byte = 0x" & hex2(b) &
               "    stop bit = " & std_logic'image(tx) severity note;
        wait;                                   -- decode a single frame
    end process;

end sim;