library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================================
-- xadc_axis_framer : XADC samples -> 16-beat AXI4-Stream frames for fft_axis.
--
--   Each 'sample' (Q5.15, on sample_valid) becomes one 40-bit AXIS beat:
--       m_tdata(19 downto 0)  = sample   (real)
--       m_tdata(39 downto 20) = 0        (imag, XADC input is real)
--   m_tlast is asserted on every FRAME-th beat (end of an FFT frame).
--
--   TVALID is HELD until TREADY accepts, so the block is safe against
--   back-pressure. (In practice the XADC rate << the FFT rate, so the FFT
--   input is essentially always ready; 'overflow' flags the impossible case
--   of a new sample arriving while the slot is still busy.)
-- ============================================================================
entity xadc_axis_framer is
    generic (
        FRAME : natural := 16          -- samples per FFT frame
    );
    port (
        clk          : in  std_logic;
        reset        : in  std_logic;                     -- active high
        -- from xadc_daq
        sample       : in  std_logic_vector(19 downto 0); -- Q5.15
        sample_valid : in  std_logic;
        -- AXI4-Stream master -> fft_axis
        m_tdata      : out std_logic_vector(39 downto 0);
        m_tvalid     : out std_logic;
        m_tready     : in  std_logic;
        m_tlast      : out std_logic;
        m_tkeep      : out std_logic_vector(4 downto 0);
        m_tstrb      : out std_logic_vector(4 downto 0);
        overflow     : out std_logic                      -- 1-cycle pulse if a sample is dropped
    );
end xadc_axis_framer;

architecture Behavioral of xadc_axis_framer is
    signal data_reg  : std_logic_vector(39 downto 0) := (others => '0');
    signal valid_reg : std_logic := '0';
    signal count     : integer range 0 to FRAME-1 := 0;   -- index of current beat in the frame
    signal ovf_reg   : std_logic := '0';
begin

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                valid_reg <= '0';
                count     <= 0;
                ovf_reg   <= '0';
                data_reg  <= (others => '0');
            else
                ovf_reg <= '0';

                -- current beat accepted -> free the slot and advance the frame count
                if valid_reg = '1' and m_tready = '1' then
                    valid_reg <= '0';
                    if count = FRAME-1 then
                        count <= 0;
                    else
                        count <= count + 1;
                    end if;
                end if;

                -- new sample -> load the beat slot (imag = 0)
                if sample_valid = '1' then
                    if valid_reg = '1' and m_tready = '0' then
                        ovf_reg <= '1';                   -- slot busy and not draining -> sample lost
                    end if;
                    data_reg(19 downto 0)  <= sample;
                    data_reg(39 downto 20) <= (others => '0');
                    valid_reg <= '1';
                end if;
            end if;
        end if;
    end process;

    m_tdata  <= data_reg;
    m_tvalid <= valid_reg;
    m_tlast  <= '1' when count = FRAME-1 else '0';
    m_tkeep  <= (others => '1');
    m_tstrb  <= (others => '1');
    overflow <= ovf_reg;

end Behavioral;
