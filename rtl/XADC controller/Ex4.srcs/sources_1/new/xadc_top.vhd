library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity xadc_top is
    port (
        dclk_in   : in  std_logic;                       -- 100 MHz
        Vaux5_v_p : in  std_logic;                       -- pot analog input (+)
        Vaux5_v_n : in  std_logic;                       -- pot analog input (-)
        led       : out std_logic_vector(7 downto 0)
    );
end xadc_top;

architecture Behavioral of xadc_top is

    ------------------------------------------------------------------
    -- XADC IP
    ------------------------------------------------------------------
    component xadc_wiz_0
        port (
            di_in    : in  std_logic_vector(15 downto 0);
            daddr_in : in  std_logic_vector(6 downto 0);
            den_in   : in  std_logic;
            dwe_in   : in  std_logic;
            drdy_out : out std_logic;
            do_out   : out std_logic_vector(15 downto 0);
            dclk_in  : in  std_logic;
            reset_in : in  std_logic;
            vp_in    : in  std_logic;
            vn_in    : in  std_logic;
            vauxp5   : in  std_logic;
            vauxn5   : in  std_logic;
            user_temp_alarm_out : out std_logic;
            vccint_alarm_out    : out std_logic;
            vccaux_alarm_out    : out std_logic;
            ot_out      : out std_logic;
            channel_out : out std_logic_vector(4 downto 0);
            eoc_out     : out std_logic;
            alarm_out   : out std_logic;
            eos_out     : out std_logic;
            busy_out    : out std_logic
        );
    end component;

    ------------------------------------------------------------------
    -- Internal signals (the DRP plumbing)
    ------------------------------------------------------------------
    constant ZERO16      : std_logic_vector(15 downto 0) := (others => '0');
    constant DADDR_VAUX5 : std_logic_vector(6 downto 0)  := "0010101"; -- 0x15

    signal drp_den  : std_logic := '0';
    signal drp_drdy : std_logic;
    signal drp_do   : std_logic_vector(15 downto 0);
    signal xadc_eoc : std_logic;

    type state_t is (WAIT_EOC, WAIT_DRDY);
    signal state : state_t := WAIT_EOC;

    signal led_reg : std_logic_vector(7 downto 0) := (others => '0');

begin

    ------------------------------------------------------------------
    -- XADC instance
    ------------------------------------------------------------------
    my_xadc : xadc_wiz_0
        port map (
            di_in    => ZERO16,            -- read-only: no write data
            daddr_in => DADDR_VAUX5,       -- VAUX5 result register (0x15)
            den_in   => drp_den,
            dwe_in   => '0',               -- read, not write
            drdy_out => drp_drdy,
            do_out   => drp_do,
            dclk_in  => dclk_in,
            reset_in => '0',
            vp_in    => '0',               -- dedicated pair unused
            vn_in    => '0',
            vauxp5   => Vaux5_v_p,
            vauxn5   => Vaux5_v_n,
            user_temp_alarm_out => open,
            vccint_alarm_out    => open,
            vccaux_alarm_out    => open,
            ot_out      => open,
            channel_out => open,
            eoc_out     => xadc_eoc,
            alarm_out   => open,
            eos_out     => open,
            busy_out    => open
        );

    ------------------------------------------------------------------
    -- DRP read FSM
    --   on end-of-conversion -> pulse den to read 0x15 ->
    --   wait for drdy -> latch top 8 bits of the 12-bit result
    ------------------------------------------------------------------
    process(dclk_in)
    begin
        if rising_edge(dclk_in) then
            case state is

                when WAIT_EOC =>
                    drp_den <= '0';
                    if xadc_eoc = '1' then
                        drp_den <= '1';            -- start the DRP read
                        state   <= WAIT_DRDY;
                    end if;

                when WAIT_DRDY =>
                    drp_den <= '0';                -- den high for one cycle only
                    if drp_drdy = '1' then
                        led_reg <= drp_do(15 downto 8);  -- top 8 of 12-bit result
                        state   <= WAIT_EOC;
                    end if;

            end case;
        end if;
    end process;

    led <= led_reg;

end Behavioral;
