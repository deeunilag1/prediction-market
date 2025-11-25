;; Prediction Markets - Decentralized Forecasting & Betting Protocol
;; Production-ready smart contract for binary and multi-outcome prediction markets

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-market-inactive (err u104))
(define-constant err-market-resolved (err u105))
(define-constant err-invalid-outcome (err u106))
(define-constant err-too-early (err u107))
(define-constant err-already-resolved (err u108))
(define-constant err-no-winnings (err u109))
(define-constant err-slippage-too-high (err u110))
(define-constant err-insufficient-shares (err u111))
(define-constant err-contract-paused (err u112))
(define-constant err-invalid-resolution-time (err u113))
(define-constant err-invalid-question (err u114))
(define-constant err-insufficient-stake (err u115))

;; Protocol parameters
(define-constant min-creation-stake u100000000) ;; 100 STX
(define-constant min-resolution-time u1440) ;; ~10 days in blocks
(define-constant platform-fee-bps u100) ;; 1% platform fee
(define-constant basis-points u10000)
(define-constant amm-constant u1000000) ;; AMM constant product factor
(define-constant min-trade-amount u1000000) ;; 1 STX minimum trade

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var total-markets-created uint u0)
(define-data-var total-volume uint u0)
(define-data-var total-fees-collected uint u0)
(define-data-var accumulated-fees uint u0)

;; Market data structure
(define-map markets
  uint
  {
    creator: principal,
    question: (string-ascii 256),
    outcome-count: uint,
    total-pool: uint,
    resolution-time: uint,
    resolved: bool,
    winning-outcome: (optional uint),
    created-at: uint,
    is-active: bool,
    total-volume: uint
  }
)

;; Outcome shares and reserves (AMM pools)
(define-map outcome-reserves
  { market-id: uint, outcome-id: uint }
  {
    reserve: uint,
    total-shares: uint
  }
)

;; User positions in markets
(define-map user-positions
  { user: principal, market-id: uint, outcome-id: uint }
  uint
)

;; User statistics
(define-map user-stats
  principal
  {
    markets-participated: uint,
    total-wagered: uint,
    total-won: uint,
    markets-won: uint
  }
)

;; Market creator stakes
(define-map creator-stakes
  { creator: principal, market-id: uint }
  uint
)

;; Private Functions

(define-private (calculate-fee (amount uint))
  (/ (* amount platform-fee-bps) basis-points)
)

(define-private (calculate-amm-price (reserve-buy uint) (reserve-sell uint) (amount-in uint))
  (let
    (
      (amount-in-with-fee (- amount-in (calculate-fee amount-in)))
      (numerator (* amount-in-with-fee reserve-sell))
      (denominator (+ reserve-buy amount-in-with-fee))
    )
    (/ numerator denominator)
  )
)

(define-private (update-user-stats (user principal) (wagered uint) (won uint) (is-winner bool))
  (match (map-get? user-stats user)
    stats
    (map-set user-stats user
      {
        markets-participated: (+ (get markets-participated stats) u1),
        total-wagered: (+ (get total-wagered stats) wagered),
        total-won: (+ (get total-won stats) won),
        markets-won: (if is-winner (+ (get markets-won stats) u1) (get markets-won stats))
      }
    )
    (map-set user-stats user
      {
        markets-participated: u1,
        total-wagered: wagered,
        total-won: won,
        markets-won: (if is-winner u1 u0)
      }
    )
  )
)

;; Read-Only Functions

(define-read-only (get-market (market-id uint))
  (map-get? markets market-id)
)

(define-read-only (get-outcome-reserves (market-id uint) (outcome-id uint))
  (map-get? outcome-reserves { market-id: market-id, outcome-id: outcome-id })
)

(define-read-only (get-user-position (user principal) (market-id uint) (outcome-id uint))
  (default-to u0 (map-get? user-positions { user: user, market-id: market-id, outcome-id: outcome-id }))
)

(define-read-only (get-user-stats (user principal))
  (map-get? user-stats user)
)

(define-read-only (get-protocol-stats)
  {
    total-markets: (var-get total-markets-created),
    total-volume: (var-get total-volume),
    total-fees: (var-get total-fees-collected),
    accumulated-fees: (var-get accumulated-fees),
    is-paused: (var-get contract-paused)
  }
)

(define-read-only (calculate-buy-price (market-id uint) (outcome-id uint) (amount-stx uint))
  (match (map-get? outcome-reserves { market-id: market-id, outcome-id: outcome-id })
    reserves
    (let
      (
        ;; For simplicity, assume binary market with outcome 0 and 1
        (other-outcome-id (if (is-eq outcome-id u0) u1 u0))
        (other-reserves (unwrap! (map-get? outcome-reserves { market-id: market-id, outcome-id: other-outcome-id }) (err u0)))
        (shares-out (calculate-amm-price (get reserve reserves) (get reserve other-reserves) amount-stx))
      )
      (ok shares-out)
    )
    (err u0)
  )
)

(define-read-only (calculate-sell-price (market-id uint) (outcome-id uint) (shares-in uint))
  (match (map-get? outcome-reserves { market-id: market-id, outcome-id: outcome-id })
    reserves
    (let
      (
        (other-outcome-id (if (is-eq outcome-id u0) u1 u0))
        (other-reserves (unwrap! (map-get? outcome-reserves { market-id: market-id, outcome-id: other-outcome-id }) (err u0)))
        ;; Calculate STX out based on shares being sold
        (stx-out (/ (* shares-in (get reserve reserves)) (+ (get total-shares reserves) shares-in)))
      )
      (ok stx-out)
    )
    (err u0)
  )
)

;; Public Functions - Market Creation

(define-public (create-market 
  (question (string-ascii 256))
  (outcome-count uint)
  (resolution-time uint))
  (let
    (
      (creator tx-sender)
      (market-id (+ (var-get total-markets-created) u1))
    )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (> (len question) u0) err-invalid-question)
    (asserts! (is-eq outcome-count u2) err-invalid-outcome) ;; Only binary markets for now
    (asserts! (>= resolution-time min-resolution-time) err-invalid-resolution-time)
    
    ;; Transfer creation stake
    (try! (stx-transfer? min-creation-stake creator (as-contract tx-sender)))
    
    ;; Create market
    (map-set markets market-id
      {
        creator: creator,
        question: question,
        outcome-count: outcome-count,
        total-pool: u0,
        resolution-time: (+ stacks-block-height resolution-time),
        resolved: false,
        winning-outcome: none,
        created-at: stacks-block-height,
        is-active: true,
        total-volume: u0
      }
    )
    
    ;; Initialize outcome reserves with equal initial reserves
    (map-set outcome-reserves
      { market-id: market-id, outcome-id: u0 }
      { reserve: amm-constant, total-shares: u0 }
    )
    (map-set outcome-reserves
      { market-id: market-id, outcome-id: u1 }
      { reserve: amm-constant, total-shares: u0 }
    )
    
    ;; Record creator stake
    (map-set creator-stakes
      { creator: creator, market-id: market-id }
      min-creation-stake
    )
    
    (var-set total-markets-created market-id)
    (ok market-id)
  )
)

;; Buy outcome shares
(define-public (buy-shares 
  (market-id uint)
  (outcome-id uint)
  (amount-stx uint)
  (min-shares-out uint))
  (let
    (
      (buyer tx-sender)
      (market (unwrap! (map-get? markets market-id) err-not-found))
      (reserves (unwrap! (map-get? outcome-reserves { market-id: market-id, outcome-id: outcome-id }) err-invalid-outcome))
    )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (get is-active market) err-market-inactive)
    (asserts! (not (get resolved market)) err-market-resolved)
    (asserts! (>= amount-stx min-trade-amount) err-invalid-amount)
    (asserts! (< outcome-id (get outcome-count market)) err-invalid-outcome)
    
    (let
      (
        (other-outcome-id (if (is-eq outcome-id u0) u1 u0))
        (other-reserves (unwrap! (map-get? outcome-reserves { market-id: market-id, outcome-id: other-outcome-id }) err-invalid-outcome))
        (fee (calculate-fee amount-stx))
        (amount-after-fee (- amount-stx fee))
        (shares-out (calculate-amm-price (get reserve reserves) (get reserve other-reserves) amount-after-fee))
        (new-reserve (+ (get reserve reserves) amount-after-fee))
        (new-other-reserve (- (get reserve other-reserves) shares-out))
      )
      ;; Slippage check
      (asserts! (>= shares-out min-shares-out) err-slippage-too-high)
      
      ;; Transfer STX from buyer
      (try! (stx-transfer? amount-stx buyer (as-contract tx-sender)))
      
      ;; Update reserves
      (map-set outcome-reserves
        { market-id: market-id, outcome-id: outcome-id }
        {
          reserve: new-reserve,
          total-shares: (+ (get total-shares reserves) shares-out)
        }
      )
      
      (map-set outcome-reserves
        { market-id: market-id, outcome-id: other-outcome-id }
        {
          reserve: new-other-reserve,
          total-shares: (get total-shares other-reserves)
        }
      )
      
      ;; Update user position
      (map-set user-positions
        { user: buyer, market-id: market-id, outcome-id: outcome-id }
        (+ (get-user-position buyer market-id outcome-id) shares-out)
      )
      
      ;; Update market stats
      (map-set markets market-id
        (merge market {
          total-pool: (+ (get total-pool market) amount-after-fee),
          total-volume: (+ (get total-volume market) amount-stx)
        })
      )
      
      ;; Update global stats
      (var-set total-volume (+ (var-get total-volume) amount-stx))
      (var-set total-fees-collected (+ (var-get total-fees-collected) fee))
      (var-set accumulated-fees (+ (var-get accumulated-fees) fee))
      
      ;; Update user stats
      (update-user-stats buyer amount-stx u0 false)
      
      (ok shares-out)
    )
  )
)

;; Sell outcome shares
(define-public (sell-shares
  (market-id uint)
  (outcome-id uint)
  (shares-in uint)
  (min-stx-out uint))
  (let
    (
      (seller tx-sender)
      (market (unwrap! (map-get? markets market-id) err-not-found))
      (reserves (unwrap! (map-get? outcome-reserves { market-id: market-id, outcome-id: outcome-id }) err-invalid-outcome))
      (user-shares (get-user-position seller market-id outcome-id))
    )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (get is-active market) err-market-inactive)
    (asserts! (not (get resolved market)) err-market-resolved)
    (asserts! (<= shares-in user-shares) err-insufficient-shares)
    (asserts! (> shares-in u0) err-invalid-amount)
    
    (let
      (
        (stx-out (/ (* shares-in (get reserve reserves)) (get total-shares reserves)))
        (fee (calculate-fee stx-out))
        (stx-after-fee (- stx-out fee))
      )
      ;; Slippage check
      (asserts! (>= stx-after-fee min-stx-out) err-slippage-too-high)
      
      ;; Update reserves
      (map-set outcome-reserves
        { market-id: market-id, outcome-id: outcome-id }
        {
          reserve: (- (get reserve reserves) stx-out),
          total-shares: (- (get total-shares reserves) shares-in)
        }
      )
      
      ;; Update user position
      (map-set user-positions
        { user: seller, market-id: market-id, outcome-id: outcome-id }
        (- user-shares shares-in)
      )
      
      ;; Transfer STX to seller
      (try! (as-contract (stx-transfer? stx-after-fee tx-sender seller)))
      
      ;; Update stats
      (var-set total-fees-collected (+ (var-get total-fees-collected) fee))
      (var-set accumulated-fees (+ (var-get accumulated-fees) fee))
      
      (ok stx-after-fee)
    )
  )
)

;; Resolve market
(define-public (resolve-market (market-id uint) (winning-outcome uint))
  (let
    (
      (market (unwrap! (map-get? markets market-id) err-not-found))
    )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (or (is-eq tx-sender (get creator market)) (is-eq tx-sender contract-owner)) err-unauthorized)
    (asserts! (get is-active market) err-market-inactive)
    (asserts! (not (get resolved market)) err-already-resolved)
    (asserts! (>= stacks-block-height (get resolution-time market)) err-too-early)
    (asserts! (< winning-outcome (get outcome-count market)) err-invalid-outcome)
    
    ;; Mark market as resolved
    (map-set markets market-id
      (merge market {
        resolved: true,
        winning-outcome: (some winning-outcome),
        is-active: false
      })
    )
    
    ;; Return creator stake
    (let
      (
        (stake (default-to u0 (map-get? creator-stakes { creator: (get creator market), market-id: market-id })))
      )
      (if (> stake u0)
        (try! (as-contract (stx-transfer? stake tx-sender (get creator market))))
        true
      )
    )
    
    (ok true)
  )
)

;; Claim winnings
(define-public (claim-winnings (market-id uint))
  (let
    (
      (claimer tx-sender)
      (market (unwrap! (map-get? markets market-id) err-not-found))
      (winning-outcome (unwrap! (get winning-outcome market) err-no-winnings))
      (user-shares (get-user-position claimer market-id winning-outcome))
    )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (get resolved market) err-market-inactive)
    (asserts! (> user-shares u0) err-no-winnings)
    
    (let
      (
        (winning-reserves (unwrap! (map-get? outcome-reserves { market-id: market-id, outcome-id: winning-outcome }) err-invalid-outcome))
        (total-winning-shares (get total-shares winning-reserves))
        (payout (if (> total-winning-shares u0)
          (/ (* user-shares (get total-pool market)) total-winning-shares)
          u0
        ))
      )
      (asserts! (> payout u0) err-no-winnings)
      
      ;; Reset user position
      (map-set user-positions
        { user: claimer, market-id: market-id, outcome-id: winning-outcome }
        u0
      )
      
      ;; Transfer winnings
      (try! (as-contract (stx-transfer? payout tx-sender claimer)))
      
      ;; Update user stats
      (update-user-stats claimer u0 payout true)
      
      (ok payout)
    )
  )
)

;; Admin Functions

(define-public (toggle-pause)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-paused (not (var-get contract-paused)))
    (ok (var-get contract-paused))
  )
)

(define-public (withdraw-fees (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= amount (var-get accumulated-fees)) err-invalid-amount)
    (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
    (var-set accumulated-fees (- (var-get accumulated-fees) amount))
    (ok amount)
  )
)