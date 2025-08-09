# Sui DLMM (Dynamic Liquidity Market Maker)

[![Sui Network](https://img.shields.io/badge/Sui-Network-blue?style=for-the-badge&logo=sui&logoColor=white)](https://sui.io/)
[![Move](https://img.shields.io/badge/Move-Language-orange?style=for-the-badge&logo=move&logoColor=white)](https://move-language.github.io/move/)
[![Testnet](https://img.shields.io/badge/Status-Live%20on%20Testnet-green?style=for-the-badge)](https://suiscan.xyz/testnet)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-Passing-brightgreen?style=for-the-badge)](tests/)

[![Package ID](https://img.shields.io/badge/Package%20ID-0x6a01a88c-blue?style=flat-square&logo=sui)](https://suiscan.xyz/testnet/object/0x6a01a88c704d76ef8b0d4db811dff4dd13104a35e7a125131fa35949d0bc2ada)
[![Factory](https://img.shields.io/badge/Factory-0x160e34d1-blue?style=flat-square&logo=sui)](https://suiscan.xyz/testnet/object/0x160e34d10029993bccf6853bb5a5140bcac1794b7c2faccc060fb3d5b7167d7f)
[![Treasury](https://img.shields.io/badge/TEST%20USDC-0x2270d377-green?style=flat-square&logo=sui)](https://suiscan.xyz/testnet/object/0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9)

A next-generation AMM protocol built on Sui blockchain featuring zero-slippage bins, dynamic fees, and superior capital efficiency.

## 🚀 **LIVE ON SUI TESTNET** 

The protocol is now deployed and fully functional on Sui Testnet! Start trading and providing liquidity today.

### 📍 **Deployed Contract Addresses (Testnet)**

#### Main DLMM Protocol
```bash
DLMM_PACKAGE_ID="0x6a01a88c704d76ef8b0d4db811dff4dd13104a35e7a125131fa35949d0bc2ada"
FACTORY_ID="0x160e34d10029993bccf6853bb5a5140bcac1794b7c2faccc060fb3d5b7167d7f"
UPGRADE_CAP="0xfe189ba6983053715ad68254c2a316cfef70f06b442ce54c7f47f3b0fbadecef"
```

#### Test Token (TEST_USDC)
```bash
TEST_USDC_PACKAGE="0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2"
TEST_USDC_TREASURY="0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9"
TOKEN_METADATA="0x9d2cdf2af2eeee436bda66f874d697e37c3cae6450009c8d8a3d5b6c692e4315"
```

## 💰 **Get Test Tokens (Anyone Can Mint!)**

### Quick Token Minting
```bash
# Get 1,000 USDC for testing
sui client call \
  --package 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2 \
  --module test_usdc \
  --function get_test_tokens \
  --args 0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9 \
  --gas-budget 10000000

# Get 10,000 USDC for liquidity provision
sui client call \
  --package 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2 \
  --module test_usdc \
  --function get_liquidity_tokens \
  --args 0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9 \
  --gas-budget 10000000

# Mint custom amount (e.g., 5,000 USDC)
sui client call \
  --package 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2 \
  --module test_usdc \
  --function mint_custom_amount \
  --args 0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9 5000000000000 \
  --gas-budget 10000000
```

### Check Your Balance
```bash
# Check your TEST_USDC balance
sui client balance --coin-type 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2::test_usdc::TEST_USDC

# Check all your coins
sui client balance
```

## 🏊 **Using the DLMM Protocol**

### Create a Pool
```bash
# Create USDC/SUI pool with 0.25% bin step
sui client call \
  --package 0x6a01a88c704d76ef8b0d4db811dff4dd13104a35e7a125131fa35949d0bc2ada \
  --module factory \
  --function create_pool_for_router \
  --type-args 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2::test_usdc::TEST_USDC 0x2::sui::SUI \
  --args 0x160e34d10029993bccf6853bb5a5140bcac1794b7c2faccc060fb3d5b7167d7f 25 1000000000000000000 1000 [YOUR_USDC_COIN_ID] [YOUR_SUI_COIN_ID] [CLOCK_ID] \
  --gas-budget 50000000
```

### Add Liquidity
```bash
# Add liquidity to existing pool
sui client call \
  --package 0x6a01a88c704d76ef8b0d4db811dff4dd13104a35e7a125131fa35949d0bc2ada \
  --module position_manager \
  --function create_and_transfer_position \
  --type-args 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2::test_usdc::TEST_USDC 0x2::sui::SUI \
  --args [POOL_ID] [YOUR_USDC_COIN_ID] [YOUR_SUI_COIN_ID] 5 1 [CLOCK_ID] \
  --gas-budget 30000000
```

## 🔧 **Development Setup**

### Prerequisites
- [Sui CLI](https://docs.sui.io/build/install) installed
- Move language support in your IDE

### Local Development
```bash
# Clone the repository
git clone <your-repo-url>
cd sui-dlmm

# Install dependencies and build
sui move build

# Run comprehensive test suite
sui move test

# Run specific test categories
sui move test test_bin_math              # Math functions
sui move test test_constant_sum          # Core AMM logic  
sui move test test_swap                  # Swap mechanics
sui move test test_position              # Position management
```

## 🏗️ **Architecture Overview**

### Core Components
- **🏊 DLMM Pool**: Main pool with discrete liquidity bins using constant sum formula
- **🏭 Factory**: Pool creation and registry management with real storage
- **📍 Position Manager**: Multi-bin liquidity position handling with strategies
- **💱 Router**: Multi-hop routing with slippage protection
- **💰 Dynamic Fees**: Volatility-based fee adjustments to compensate LPs

### Key Innovations
- **⚡ Zero Slippage**: Trades within bins have zero price impact
- **📈 Dynamic Fees**: Fees increase during volatility to compensate LPs
- **💪 Capital Efficiency**: >200% improvement vs traditional AMMs
- **🎯 Flexible Strategies**: Uniform, curve, and bid-ask distributions

## 🧮 **Mathematical Foundation**

### Constant Sum Per Bin
```
P × x + y = L
```
Where:
- `P` = bin price (constant within bin)
- `x` = token X reserves  
- `y` = token Y reserves
- `L` = total liquidity in bin

### Bin Price Calculation
```
Price(bin_id) = (1 + bin_step/10000)^bin_id
```

### Dynamic Fee Formula
```
total_fee = base_fee + variable_fee(volatility)
```

## 📊 **Test Coverage**

The project includes comprehensive tests covering:

### ✅ Core Mathematics
- [x] Bin price calculations (`test_bin_math_price_calculation`)
- [x] Constant sum invariant (`test_constant_sum_math`)  
- [x] Power function accuracy
- [x] Fixed-point arithmetic

### ✅ Swap Mechanics
- [x] Zero-slippage within bins (`test_swap_within_bin`)
- [x] Multi-bin traversal (`test_multi_bin_swap`)
- [x] Price impact calculation
- [x] Bin exhaustion handling

### ✅ Liquidity Management  
- [x] Position creation (`test_position_creation`)
- [x] Distribution strategies (`test_liquidity_distribution_strategies`)
- [x] Fee collection (`test_fee_collection`)
- [x] Multiple position handling

### ✅ Advanced Features
- [x] Dynamic fee calculation (`test_dynamic_fees`)
- [x] Volatility tracking
- [x] Large trade handling
- [x] Edge case validation

## 🛠️ **Development Phases**

### ✅ Phase 1: Core Implementation (COMPLETED)
- [x] Project setup and comprehensive tests
- [x] Core math functions (`bin_math.move`, `constant_sum.move`)
- [x] Pool implementation (`dlmm_pool.move`)
- [x] Position management (`position.move`)
- [x] Factory implementation (`factory.move`)
- [x] **DEPLOYED TO TESTNET** 🎉

### 🚧 Phase 2: Advanced Features (IN PROGRESS)
- [x] Multi-bin routing (`router.move`)
- [x] Price quotation (`quoter.move`) 
- [ ] Automated strategies
- [ ] Flash loan support

### 📋 Phase 3: Ecosystem Integration (PLANNED)
- [ ] TypeScript SDK
- [ ] Frontend components
- [ ] Cross-protocol integrations
- [ ] Governance framework

## 🧪 **Running Tests**

### All Tests
```bash
sui move test
```

### Specific Test Categories
```bash
# Mathematical functions
sui move test test_bin_math_price_calculation
sui move test test_constant_sum_math

# Swap mechanics  
sui move test test_swap_within_bin
sui move test test_multi_bin_swap

# Liquidity management
sui move test test_position_creation
sui move test test_liquidity_distribution_strategies

# Fee system
sui move test test_dynamic_fees
sui move test test_fee_collection

# Advanced scenarios
sui move test test_price_impact_calculation
```

### Test with Coverage
```bash
sui move test --coverage
sui move coverage summary
```

## 📈 **Performance Targets**

- **Single Bin Swap**: <100k gas units
- **Multi-Bin Swap**: <500k gas units
- **Position Creation**: <200k gas units  
- **Fee Collection**: <50k gas units

## 🛡️ **Security Features**

- **Formal Verification**: Leverages Move's safety guarantees
- **Invariant Checking**: Mathematical invariants enforced
- **Overflow Protection**: Safe arithmetic operations
- **Access Control**: Proper permission management
- **Circuit Breakers**: Emergency pause mechanisms

## 🌐 **Testnet Explorer Links (Suiscan)**

- **📦 Main DLMM Package**: [View on Suiscan](https://suiscan.xyz/testnet/object/0x6a01a88c704d76ef8b0d4db811dff4dd13104a35e7a125131fa35949d0bc2ada) - Complete protocol modules
- **🏭 Factory Contract**: [View on Suiscan](https://suiscan.xyz/testnet/object/0x160e34d10029993bccf6853bb5a5140bcac1794b7c2faccc060fb3d5b7167d7f) - Pool creation & management
- **💰 TEST_USDC Package**: [View on Suiscan](https://suiscan.xyz/testnet/object/0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2) - Test token implementation
- **🏛️ SharedTreasury**: [View on Suiscan](https://suiscan.xyz/testnet/object/0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9) - Token minting contract

### 📊 **Live Analytics**
- **📈 Protocol Stats**: [View on SuiVision](https://suivision.xyz/testnet)
- **💹 Token Metrics**: [TEST_USDC Analytics](https://suiscan.xyz/testnet/coin/0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2::test_usdc::TEST_USDC)
- **🔍 Transaction History**: [Your Address Analytics](https://suiscan.xyz/testnet/address/)

## 📚 **Documentation**

- [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) - Technical architecture details
- [`API.md`](docs/API.md) - API reference and usage examples
- [`MATH.md`](docs/MATH.md) - Mathematical specifications and proofs

## 🤝 **Contributing**

1. **Fork the repository**
2. **Create feature branch**: `git checkout -b feature/your-feature`
3. **Write tests first**: Add tests in `tests/` directory
4. **Implement feature**: Add implementation in `sources/`
5. **Verify tests pass**: `sui move test`
6. **Submit pull request**

### Code Style
- Follow Move language conventions
- Add comprehensive tests for new features
- Include inline documentation
- Validate mathematical correctness

## 📄 **License**

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 **Acknowledgments**

- **Sui Foundation** for the innovative blockchain platform
- **Meteora** for pioneering DLMM on Solana  
- **Trader Joe** for the original Liquidity Book concept
- **Uniswap** for concentrated liquidity innovations

---

**🔥 Live on Sui Testnet - Built with ❤️ for the next generation of DeFi**

### 🚀 **Quick Start Commands**
```bash
# 1. Get test tokens
sui client call --package 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2 --module test_usdc --function get_test_tokens --args 0x2270d37729375d0b1446c101303f65a24677ae826ed3a39a4bb9c744f77537e9 --gas-budget 10000000

# 2. Check balance
sui client balance --coin-type 0xbeb0bfff8de500ffd56210e21fc506a3e67bbef45cb65a515d72b223770e3ab2::test_usdc::TEST_USDC

# 3. Start building your DeFi application!
```

## 📊 **Stats & Metrics**

![Contracts](https://img.shields.io/badge/Smart%20Contracts-Deployed-success?style=flat-square)
![Gas Optimized](https://img.shields.io/badge/Gas-Optimized-blue?style=flat-square)
![Zero Slippage](https://img.shields.io/badge/Zero%20Slippage-Enabled-green?style=flat-square)
![Dynamic Fees](https://img.shields.io/badge/Dynamic%20Fees-Active-orange?style=flat-square)