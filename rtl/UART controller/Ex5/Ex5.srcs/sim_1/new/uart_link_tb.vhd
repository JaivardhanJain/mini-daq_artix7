library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_link_tb is
end uart_link_tb;

architecture sim of uart_link_tb is

    constant CLK_PERIOD : time := 10 ns;      -- 100 MHz

    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal running : boolean   := true;

    signal tx_start : std_logic := '0';
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_busy  : std_logic;

    signal line : std_logic;                  -- the wire between TX and RX

    signal rx_data : std_logic_vector(7 downto 0);
    signal rx_done : std_logic;

    function hex2(v : std_logic_vector(7 downto 0)) return string is
        constant hc : string(1 to 16) := "0123456789ABCDEF";
        variable s  : string(1 to 2);
    begin
        s(1) := hc(to_integer(unsigned(v(7 downto 4))) + 1);
        s(2) := hc(to_integer(unsigned(v(3 downto 0))) + 1);
        return s;
    end function;

begin

    u_tx : entity work.uart_tx
        port map (
            clk => clk, reset => reset,
            tx_start => tx_start, data_in => tx_data,
            tx => line, tx_busy => tx_busy
        );

    u_rx : entity work.uart_rx
        port map (
            clk => clk, reset => reset,
            rx => line, data_out => rx_data, rx_done => rx_done
        );

    clk <= (not clk) after CLK_PERIOD / 2 when running else '0';

    stim : process

        procedure send(b : std_logic_vector(7 downto 0)) is
        begin
            while tx_busy = '1' loop        -- wait until the transmitter is free
                wait until rising_edge(clk);
            end loop;
            tx_data  <= b;
            tx_start <= '1';
            wait until rising_edge(clk);
            tx_start <= '0';

            wait until rx_done = '1';
            wait until rising_edge(clk);

            if rx_data = b then
                report "OK   sent 0x" & hex2(b) &
                       "  received 0x" & hex2(rx_data) severity note;
            else
                report "FAIL sent 0x" & hex2(b) &
                       "  received 0x" & hex2(rx_data) severity error;
            end if;
        end procedure;

    begin
        reset <= '1';
        wait for 100 ns;
        reset <= '0';
        wait for 50 ns;

        send(x"53");    -- 'S'
        send(x"A6");    -- another pattern
        send(x"00");
        send(x"FF");
        send(x"55");
        send(x"AA");

        report "=== Simulation finished ===" severity note;
        running <= false;
        wait;
    end process;

end sim;
