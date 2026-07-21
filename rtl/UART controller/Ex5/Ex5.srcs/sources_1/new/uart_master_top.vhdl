library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity uart_master_top is
    port (
        clk   : in  std_logic;
        sw    : in  std_logic_vector(7 downto 0);   -- 8 slide switches
        tx    : out std_logic                       -- UART serial output pin
    );
end uart_master_top;

architecture Behavioral of uart_master_top is

    component uart_tx
        port (
            clk      : in  std_logic;
            reset    : in  std_logic;
            tx_start : in  std_logic;
            data_in  : in  std_logic_vector(7 downto 0);
            tx       : out std_logic;
            tx_busy  : out std_logic
        );
    end component;

    signal tx_start : std_logic := '0';
    signal tx_busy  : std_logic;

begin

    -- the transmitter you already built; sends the switch value out 'tx'
    u_tx : uart_tx
        port map (
            clk      => clk,
            reset    => '0',
            tx_start => tx_start,
            data_in  => sw,          -- the switch byte is the payload
            tx       => tx,
            tx_busy  => tx_busy
        );

    -- TODO: drive tx_start so a new frame launches whenever the transmitter
    --       is free (tx_busy = '0'), and is low while it is busy.
    --       This is the "never start while busy" rule from the sim, as one
    --       continuous assignment. (Single line, no process needed.)
    -- tx_start <= ... ;
    tx_start <= not tx_busy;
    
end Behavioral;