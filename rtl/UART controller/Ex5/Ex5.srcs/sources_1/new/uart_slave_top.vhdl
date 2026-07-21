library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity uart_slave_top is
    port (
        clk   : in  std_logic;
        rx    : in  std_logic;                       -- UART serial input pin
        led   : out std_logic_vector(7 downto 0)     -- 8 LEDs
    );
end uart_slave_top;

architecture Behavioral of uart_slave_top is

    component uart_rx
        port (
            clk      : in  std_logic;
            reset    : in  std_logic;
            rx       : in  std_logic;
            data_out : out std_logic_vector(7 downto 0);
            rx_done  : out std_logic
        );
    end component;

    signal rx_data : std_logic_vector(7 downto 0);
    signal rx_done : std_logic;
    signal led_reg : std_logic_vector(7 downto 0) := (others => '0');

begin

    -- the receiver you already built; recovers a byte from 'rx'
    u_rx : uart_rx
        port map (
            clk      => clk,
            reset    => '0',
            rx       => rx,
            data_out => rx_data,
            rx_done  => rx_done
        );

    -- Hold the last received byte on the LEDs; update only when a byte arrives.
    process(clk)
    begin
        if rising_edge(clk) then
            if rx_done = '1' then
                led_reg <= rx_data;
            end if;
        end if;
    end process;

    led <= led_reg;

end Behavioral;