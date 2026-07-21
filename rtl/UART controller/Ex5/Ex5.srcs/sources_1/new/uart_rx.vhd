library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx is
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        rx       : in  std_logic;                      -- serial line (idles high)
        data_out : out std_logic_vector(7 downto 0);   -- received byte
        rx_done  : out std_logic                       -- 1-cycle pulse when byte ready
    );
end uart_rx;

architecture Behavioral of uart_rx is

    constant BAUD_DIV  : integer := 868;    -- one bit period  (100 MHz / 115200)
    constant HALF_BAUD : integer := 434;    -- half a bit period (start-bit center)

    -- 2-FF synchronizer for the asynchronous rx input
    signal rx_meta : std_logic := '1';
    signal rx_sync : std_logic := '1';

    type state_t is (IDLE, START, DATA, STOP);
    signal state : state_t := IDLE;

    signal clk_cnt : integer range 0 to BAUD_DIV-1 := 0;
    signal bit_cnt : integer range 0 to 7 := 0;

    signal data_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_done_reg : std_logic := '0';

begin

    ------------------------------------------------------------------
    -- Synchronize rx through two flip-flops (metastability guard).
    -- Use rx_sync everywhere below, never the raw rx pin.
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Receive FSM:  IDLE -> START -> DATA (x8, LSB first) -> STOP
    -- Sample at bit centers: half a bit into the start bit, then full bits.
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state       <= IDLE;
                clk_cnt     <= 0;
                bit_cnt     <= 0;
                data_reg    <= (others => '0');
                rx_done_reg <= '0';
            else
                rx_done_reg <= '0';        -- default; make it a one-cycle pulse
                case state is

                    when IDLE =>
                        -- TODO: watch for the start-bit falling edge (rx_sync = '0').
                        --       When seen: reset clk_cnt and go to START.
                        if rx_sync = '0' then
                            clk_cnt <= 0;
                            state   <= START;
                        end if;

                    when START =>
                        if clk_cnt = HALF_BAUD-1 then          -- reached the center of the start bit
                            if rx_sync = '0' then              -- still low? valid start
                                clk_cnt <= 0;
                                bit_cnt <= 0;
                                state   <= DATA;
                            else
                                state <= IDLE;                 -- went high -> was a glitch
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;            -- one tick closer to center
                        end if;

                    when DATA =>
                        -- TODO: count clk_cnt up to BAUD_DIV-1 (next bit center).
                        --       At the center: sample rx_sync into data_reg, LSB first
                        --         (shift right, insert at top):
                        --         data_reg <= rx_sync & data_reg(7 downto 1);
                        --       reset clk_cnt; after the 8th bit go to STOP, else stay.
                        if clk_cnt = BAUD_DIV - 1 then          -- reached the center of the start bit
                            data_reg <= rx_sync & data_reg(7 downto 1);
                            clk_cnt  <= 0;
                            if bit_cnt = 7 then
                                state <= STOP; 
                            else
                                state   <= DATA;
                                bit_cnt <= bit_cnt + 1;                
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;            -- one tick closer to center
                            state   <= DATA;
                        end if;

                    when STOP =>
                        -- TODO: count clk_cnt up to BAUD_DIV-1 (center of stop bit).
                        --       There: pulse rx_done_reg <= '1' and return to IDLE.
                        --       (optionally check rx_sync = '1' for a valid stop bit)
                        if clk_cnt = BAUD_DIV - 1 then          -- reached the center of the start bit
                            rx_done_reg <= '1';
                            state       <= IDLE;
                        else
                            clk_cnt <= clk_cnt + 1;            -- one tick closer to center
                        end if;
                end case;
            end if;
        end if;
    end process;

    data_out <= data_reg;
    rx_done  <= rx_done_reg;

end Behavioral;