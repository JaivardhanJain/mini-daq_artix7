library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- daq_sampler : XADC DRP-read FSM + 12-bit -> Q5.15 conversion.
--
-- Pure logic (no IP), so it can be UNIT-TESTED by driving eoc/drdy/do directly
-- (mocking the DRP side) with no analog stimulus. xadc_daq wires the real
-- xadc_wiz IP to this block.
--
-- Conversion (per drdy):
--   raw12    = do_in(15 downto 4)          -- full 12-bit result
--   centered = raw12 - 2048  (unipolar)    -- mid-rail -> 0, signed -2048..2047
--            = signed(raw12) (bipolar)     -- XADC already returns signed
--   sample   = centered << SHIFT           -- ADC full-scale -> Q5.15 +/-1.0
-- ============================================================================
entity daq_sampler is
    generic (
        BIPOLAR : boolean := false;   -- false: unipolar 0..1V (subtract mid-scale). true: XADC returns signed.
        SHIFT   : natural := 4        -- ADC full-scale -> Q5.15 +/-1.0
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;                     -- active high
        eoc_in       : in  std_logic;                     -- end-of-conversion (from XADC)
        drdy_in      : in  std_logic;                     -- DRP data ready (from XADC)
        do_in        : in  std_logic_vector(15 downto 0); -- DRP data (12-bit result in [15:4])
        den_out      : out std_logic;                     -- DRP read strobe (to XADC)
        sample       : out std_logic_vector(19 downto 0); -- Q5.15 signed sample
        sample_valid : out std_logic                      -- one-cycle pulse when 'sample' is new
    );
end daq_sampler;

architecture Behavioral of daq_sampler is

    type state_t is (WAIT_EOC, WAIT_DRDY);
    signal state : state_t := WAIT_EOC;

    signal den_reg    : std_logic := '0';
    signal valid_reg  : std_logic := '0';
    signal sample_reg : std_logic_vector(19 downto 0) := (others => '0');

begin

    -- DRP-read FSM: on end-of-conversion, pulse den to read the result reg,
    -- wait for drdy, convert to Q5.15, and emit a one-cycle sample_valid.
    process(clk)
        variable raw12    : unsigned(11 downto 0);
        variable centered : signed(12 downto 0);   -- holds -2048..2047
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state      <= WAIT_EOC;
                den_reg    <= '0';
                valid_reg  <= '0';
                sample_reg <= (others => '0');
            else
                valid_reg <= '0';                       -- default: make valid a 1-cycle pulse
                case state is

                    when WAIT_EOC =>
                        den_reg <= '0';
                        if eoc_in = '1' then
                            den_reg <= '1';             -- start the DRP read
                            state   <= WAIT_DRDY;
                        end if;

                    when WAIT_DRDY =>
                        den_reg <= '0';                 -- den high for one cycle only
                        if drdy_in = '1' then
                            raw12 := unsigned(do_in(15 downto 4));   -- full 12-bit result
                            if BIPOLAR then
                                centered := resize(signed(raw12), 13);          -- already signed
                            else
                                centered := signed(resize(raw12, 13)) - 2048;   -- center on mid-scale
                            end if;
                            sample_reg <= std_logic_vector(shift_left(resize(centered, 20), SHIFT));
                            valid_reg  <= '1';          -- new sample ready
                            state      <= WAIT_EOC;
                        end if;

                end case;
            end if;
        end if;
    end process;

    den_out      <= den_reg;
    sample       <= sample_reg;
    sample_valid <= valid_reg;

end Behavioral;
