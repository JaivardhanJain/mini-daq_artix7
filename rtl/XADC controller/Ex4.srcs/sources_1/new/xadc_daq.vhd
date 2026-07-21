library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- ============================================================================
-- xadc_daq : DAQ front-end.  VAUX5 analog input -> Q5.15 sample stream.
--
-- Wraps the xadc_wiz_0 IP (single-channel VAUX5, continuous) and the
-- daq_sampler conversion logic. Emits one Q5.15 'sample' + 'sample_valid'
-- pulse per conversion, ready to feed the FFT's AXI-Stream framer.
--
-- The pot->LED demo (xadc_top.vhd) is left untouched as a fallback.
-- ============================================================================
entity xadc_daq is
    generic (
        DADDR   : std_logic_vector(6 downto 0) := "0010101";  -- 0x15 = VAUX5 result reg (must match the IP's enabled channel)
        BIPOLAR : boolean := false;                            -- false: unipolar 0..1V + external mid-rail bias
        SHIFT   : natural := 4                                 -- ADC full-scale -> Q5.15 +/-1.0
    );
    port (
        dclk_in      : in  std_logic;                     -- 100 MHz
        reset        : in  std_logic;                     -- active high
        Vaux5_v_p    : in  std_logic;                     -- analog input (+)  [conditioned to 0..1V]
        Vaux5_v_n    : in  std_logic;                     -- analog input (-)
        sample       : out std_logic_vector(19 downto 0); -- Q5.15 signed sample
        sample_valid : out std_logic                      -- one-cycle pulse per new sample
    );
end xadc_daq;

architecture Behavioral of xadc_daq is

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

    component daq_sampler
        generic (
            BIPOLAR : boolean;
            SHIFT   : natural
        );
        port (
            clk          : in  std_logic;
            reset        : in  std_logic;
            eoc_in       : in  std_logic;
            drdy_in      : in  std_logic;
            do_in        : in  std_logic_vector(15 downto 0);
            den_out      : out std_logic;
            sample       : out std_logic_vector(19 downto 0);
            sample_valid : out std_logic
        );
    end component;

    constant ZERO16 : std_logic_vector(15 downto 0) := (others => '0');

    signal s_den  : std_logic;
    signal s_drdy : std_logic;
    signal s_eoc  : std_logic;
    signal s_do   : std_logic_vector(15 downto 0);

begin

    my_xadc : xadc_wiz_0
        port map (
            di_in    => ZERO16,          -- read-only: no write data
            daddr_in => DADDR,           -- VAUX5 result register
            den_in   => s_den,
            dwe_in   => '0',             -- read, not write
            drdy_out => s_drdy,
            do_out   => s_do,
            dclk_in  => dclk_in,
            reset_in => reset,
            vp_in    => '0',             -- dedicated pair unused
            vn_in    => '0',
            vauxp5   => Vaux5_v_p,
            vauxn5   => Vaux5_v_n,
            user_temp_alarm_out => open,
            vccint_alarm_out    => open,
            vccaux_alarm_out    => open,
            ot_out      => open,
            channel_out => open,
            eoc_out     => s_eoc,
            alarm_out   => open,
            eos_out     => open,
            busy_out    => open
        );

    u_sampler : daq_sampler
        generic map (
            BIPOLAR => BIPOLAR,
            SHIFT   => SHIFT
        )
        port map (
            clk          => dclk_in,
            reset        => reset,
            eoc_in       => s_eoc,
            drdy_in      => s_drdy,
            do_in        => s_do,
            den_out      => s_den,
            sample       => sample,
            sample_valid => sample_valid
        );

end Behavioral;
