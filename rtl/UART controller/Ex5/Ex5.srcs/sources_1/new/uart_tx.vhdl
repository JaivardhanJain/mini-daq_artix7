library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx is
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        tx_start : in  std_logic;                     -- pulse to begin sending
        data_in  : in  std_logic_vector(7 downto 0);  -- byte to send
        tx       : out std_logic;                     -- serial line (idles high)
        tx_busy  : out std_logic                      -- high while sending
    );
end uart_tx;

architecture Behavioral of uart_tx is

    -- 100 MHz / 115200 baud = 868 cycles per bit
    constant BAUD_DIV : integer := 868;

    type state_t is (IDLE, START, DATA, STOP);
    signal state : state_t := IDLE;

    signal baud_cnt  : integer range 0 to BAUD_DIV-1 := 0;
    signal baud_tick : std_logic := '0';

    signal shift_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_cnt   : integer range 0 to 7 := 0;

    signal tx_reg : std_logic := '1';   -- line idles high

begin

    ------------------------------------------------------------------
    -- Baud tick: pulse 'baud_tick' once every BAUD_DIV clock cycles
    ------------------------------------------------------------------
    process(clk)
        begin
            if rising_edge(clk) then
                if state = IDLE then
                    baud_cnt  <= 0;
                    baud_tick <= '0';
                elsif baud_cnt = BAUD_DIV-1 then
                    baud_tick <= '1';
                    baud_cnt  <= 0;
                else
                    baud_tick <= '0';
                    baud_cnt  <= baud_cnt + 1;
                end if;
            end if;
        end process;

    ------------------------------------------------------------------
    -- Transmit FSM:  IDLE -> START -> DATA (x8, LSB first) -> STOP
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state     <= IDLE;
                tx_reg    <= '1';
                bit_cnt   <= 0;
                shift_reg <= (others => '0');
            else
                case state is
                    when IDLE =>
                        tx_reg <= '1';
                        if (tx_start = '1') then
                            shift_reg <= data_in;
                            bit_cnt <= 0;
                            state <= START;
                        end if;
  
                    when START =>
                        tx_reg <= '0';                 -- start bit (line low)
                        if (baud_tick = '1') then state <= DATA;
                        end if;

                    when DATA =>
                        tx_reg <= shift_reg(0);
                        if baud_tick = '1' then
                            if bit_cnt = 7 then
                                state <= STOP;                              -- bit7 period done
                            else
                                shift_reg(6 downto 0) <= shift_reg(7 downto 1);
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        end if;
                        
                    when STOP =>
                        tx_reg <= '1';                 -- stop bit (line high)
                        -- TODO: on baud_tick, return to IDLE.
                        if (baud_tick = '1') then state <= IDLE; end if;

                end case;
            end if;
        end if;
    end process;

    tx      <= tx_reg;
    tx_busy <= '0' when state = IDLE else '1';

end Behavioral;
