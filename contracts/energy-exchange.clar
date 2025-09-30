;; Energy Exchange Smart Contract
;; Peer-to-peer renewable energy trading platform for solar panel owners
;; and energy consumers with smart meter integration and automated payments

;; Constants
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-INVALID-INPUT (err u422))
(define-constant ERR-INSUFFICIENT-ENERGY (err u400))
(define-constant ERR-INSUFFICIENT-FUNDS (err u402))
(define-constant ERR-PRODUCER-EXISTS (err u409))
(define-constant ERR-CONSUMER-EXISTS (err u410))
(define-constant ERR-INVALID-PRICE (err u411))
(define-constant ERR-TRANSACTION-FAILED (err u500))
(define-constant ERR-PRODUCER-INACTIVE (err u412))

(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-PRICE-PER-KWH u1000) ;; Maximum price in micro-STX per kWh
(define-constant MIN-ENERGY-UNIT u1) ;; Minimum energy unit in kWh

;; Transaction status constants
(define-constant STATUS-PENDING "pending")
(define-constant STATUS-COMPLETED "completed")
(define-constant STATUS-CANCELLED "cancelled")
(define-constant STATUS-FAILED "failed")

;; Data Structures

;; Energy producer registry
(define-map energy-producers
  { producer-id: uint }
  {
    owner: principal,
    capacity: uint, ;; Total capacity in kWh
    location: (string-ascii 100),
    meter-id: (string-ascii 50),
    total-generated: uint,
    available-energy: uint,
    price-per-kwh: uint, ;; Price in micro-STX
    is-active: bool,
    registration-timestamp: uint,
    total-transactions: uint
  }
)

;; Energy consumer registry
(define-map energy-consumers
  { consumer: principal }
  {
    registration-timestamp: uint,
    total-purchased: uint,
    total-spent: uint,
    preferred-max-price: uint,
    is-active: bool
  }
)

;; Energy listings - available energy for sale
(define-map energy-listings
  { listing-id: uint }
  {
    producer-id: uint,
    energy-amount: uint, ;; Available energy in kWh
    price-per-kwh: uint,
    timestamp: uint,
    is-available: bool,
    min-purchase: uint
  }
)

;; Energy transactions
(define-map energy-transactions
  { transaction-id: uint }
  {
    producer-id: uint,
    consumer: principal,
    energy-amount: uint,
    price-per-kwh: uint,
    total-cost: uint,
    timestamp: uint,
    status: (string-ascii 10),
    delivery-confirmed: bool
  }
)

;; Renewable Energy Certificates (RECs)
(define-map rec-certificates
  { rec-id: uint }
  {
    producer-id: uint,
    energy-amount: uint,
    generation-timestamp: uint,
    certificate-hash: (buff 32),
    is-transferred: bool,
    current-owner: principal
  }
)

;; Energy payments and balances
(define-map producer-balances
  { producer: principal }
  { balance: uint }
)

;; Global counters
(define-data-var next-producer-id uint u1)
(define-data-var next-listing-id uint u1)
(define-data-var next-transaction-id uint u1)
(define-data-var next-rec-id uint u1)
(define-data-var total-energy-traded uint u0)
(define-data-var total-transactions uint u0)

;; Private Functions

;; Validate energy producer exists and is active
(define-private (is-active-producer (producer-id uint))
  (match (map-get? energy-producers { producer-id: producer-id })
    producer (get is-active producer)
    false
  )
)

;; Validate energy consumer is registered and active
(define-private (is-active-consumer (consumer principal))
  (match (map-get? energy-consumers { consumer: consumer })
    consumer-data (get is-active consumer-data)
    false
  )
)

;; Calculate transaction cost
(define-private (calculate-cost (energy-amount uint) (price-per-kwh uint))
  (* energy-amount price-per-kwh)
)

;; Update producer statistics
(define-private (update-producer-stats (producer-id uint) (energy-sold uint) (transaction-count uint))
  (let
    (
      (producer (unwrap-panic (map-get? energy-producers { producer-id: producer-id })))
    )
    (map-set energy-producers
      { producer-id: producer-id }
      (merge producer {
        available-energy: (- (get available-energy producer) energy-sold),
        total-transactions: (+ (get total-transactions producer) transaction-count)
      })
    )
  )
)

;; Update consumer statistics
(define-private (update-consumer-stats (consumer principal) (energy-purchased uint) (amount-spent uint))
  (let
    (
      (consumer-data (unwrap-panic (map-get? energy-consumers { consumer: consumer })))
    )
    (map-set energy-consumers
      { consumer: consumer }
      (merge consumer-data {
        total-purchased: (+ (get total-purchased consumer-data) energy-purchased),
        total-spent: (+ (get total-spent consumer-data) amount-spent)
      })
    )
  )
)

;; Generate REC certificate
(define-private (generate-rec (producer-id uint) (energy-amount uint) (generation-timestamp uint))
  (let
    (
      (rec-id (var-get next-rec-id))
      (producer (unwrap-panic (map-get? energy-producers { producer-id: producer-id })))
      (cert-hash (keccak256 (unwrap-panic (to-consensus-buff? rec-id))))
    )
    (map-set rec-certificates
      { rec-id: rec-id }
      {
        producer-id: producer-id,
        energy-amount: energy-amount,
        generation-timestamp: generation-timestamp,
        certificate-hash: cert-hash,
        is-transferred: false,
        current-owner: (get owner producer)
      }
    )
    (var-set next-rec-id (+ rec-id u1))
    rec-id
  )
)

;; Public Functions

;; Register energy producer (solar panel owner)
(define-public (register-energy-producer
    (capacity uint)
    (location (string-ascii 100))
    (meter-id (string-ascii 50))
    (price-per-kwh uint)
  )
  (let
    (
      (producer-id (var-get next-producer-id))
      (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    )
    (asserts! (> capacity u0) ERR-INVALID-INPUT)
    (asserts! (> (len location) u0) ERR-INVALID-INPUT)
    (asserts! (> (len meter-id) u0) ERR-INVALID-INPUT)
    (asserts! (and (> price-per-kwh u0) (<= price-per-kwh MAX-PRICE-PER-KWH)) ERR-INVALID-PRICE)
    
    ;; Create producer record
    (map-set energy-producers
      { producer-id: producer-id }
      {
        owner: tx-sender,
        capacity: capacity,
        location: location,
        meter-id: meter-id,
        total-generated: u0,
        available-energy: u0,
        price-per-kwh: price-per-kwh,
        is-active: true,
        registration-timestamp: current-time,
        total-transactions: u0
      }
    )
    
    ;; Initialize producer balance
    (map-set producer-balances
      { producer: tx-sender }
      { balance: u0 }
    )
    
    ;; Update counter
    (var-set next-producer-id (+ producer-id u1))
    
    (ok producer-id)
  )
)

;; Register energy consumer
(define-public (register-energy-consumer (preferred-max-price uint))
  (let
    (
      (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    )
    (asserts! (<= preferred-max-price MAX-PRICE-PER-KWH) ERR-INVALID-PRICE)
    (asserts! (is-none (map-get? energy-consumers { consumer: tx-sender })) ERR-CONSUMER-EXISTS)
    
    ;; Create consumer record
    (map-set energy-consumers
      { consumer: tx-sender }
      {
        registration-timestamp: current-time,
        total-purchased: u0,
        total-spent: u0,
        preferred-max-price: preferred-max-price,
        is-active: true
      }
    )
    
    (ok true)
  )
)

;; Add energy production (from smart meter)
(define-public (add-energy-production (producer-id uint) (energy-amount uint))
  (let
    (
      (producer (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-NOT-FOUND))
      (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    )
    (asserts! (is-eq tx-sender (get owner producer)) ERR-UNAUTHORIZED)
    (asserts! (get is-active producer) ERR-PRODUCER-INACTIVE)
    (asserts! (> energy-amount u0) ERR-INVALID-INPUT)
    
    ;; Update producer energy availability
    (map-set energy-producers
      { producer-id: producer-id }
      (merge producer {
        total-generated: (+ (get total-generated producer) energy-amount),
        available-energy: (+ (get available-energy producer) energy-amount)
      })
    )
    
    ;; Generate REC certificate
    (let
      (
        (rec-id (generate-rec producer-id energy-amount current-time))
      )
      (ok rec-id)
    )
  )
)

;; List energy for sale
(define-public (list-energy-for-sale
    (producer-id uint)
    (energy-amount uint)
    (price-per-kwh uint)
    (min-purchase uint)
  )
  (let
    (
      (listing-id (var-get next-listing-id))
      (producer (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-NOT-FOUND))
      (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    )
    (asserts! (is-eq tx-sender (get owner producer)) ERR-UNAUTHORIZED)
    (asserts! (is-active-producer producer-id) ERR-PRODUCER-INACTIVE)
    (asserts! (>= (get available-energy producer) energy-amount) ERR-INSUFFICIENT-ENERGY)
    (asserts! (and (> price-per-kwh u0) (<= price-per-kwh MAX-PRICE-PER-KWH)) ERR-INVALID-PRICE)
    (asserts! (and (>= energy-amount min-purchase) (>= min-purchase MIN-ENERGY-UNIT)) ERR-INVALID-INPUT)
    
    ;; Create energy listing
    (map-set energy-listings
      { listing-id: listing-id }
      {
        producer-id: producer-id,
        energy-amount: energy-amount,
        price-per-kwh: price-per-kwh,
        timestamp: current-time,
        is-available: true,
        min-purchase: min-purchase
      }
    )
    
    ;; Update listing counter
    (var-set next-listing-id (+ listing-id u1))
    
    (ok listing-id)
  )
)

;; Purchase energy from listing
(define-public (purchase-energy (listing-id uint) (energy-amount uint))
  (let
    (
      (listing (unwrap! (map-get? energy-listings { listing-id: listing-id }) ERR-NOT-FOUND))
      (producer-id (get producer-id listing))
      (producer (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-NOT-FOUND))
      (transaction-id (var-get next-transaction-id))
      (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
      (total-cost (calculate-cost energy-amount (get price-per-kwh listing)))
    )
    (asserts! (is-active-consumer tx-sender) ERR-UNAUTHORIZED)
    (asserts! (get is-available listing) ERR-NOT-FOUND)
    (asserts! (>= (get energy-amount listing) energy-amount) ERR-INSUFFICIENT-ENERGY)
    (asserts! (>= energy-amount (get min-purchase listing)) ERR-INVALID-INPUT)
    (asserts! (>= (stx-get-balance tx-sender) total-cost) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer payment to producer
    (try! (stx-transfer? total-cost tx-sender (get owner producer)))
    
    ;; Create transaction record
    (map-set energy-transactions
      { transaction-id: transaction-id }
      {
        producer-id: producer-id,
        consumer: tx-sender,
        energy-amount: energy-amount,
        price-per-kwh: (get price-per-kwh listing),
        total-cost: total-cost,
        timestamp: current-time,
        status: STATUS-COMPLETED,
        delivery-confirmed: true
      }
    )
    
    ;; Update listing availability
    (map-set energy-listings
      { listing-id: listing-id }
      (merge listing {
        energy-amount: (- (get energy-amount listing) energy-amount),
        is-available: (> (- (get energy-amount listing) energy-amount) u0)
      })
    )
    
    ;; Update statistics
    (update-producer-stats producer-id energy-amount u1)
    (update-consumer-stats tx-sender energy-amount total-cost)
    
    ;; Update global counters
    (var-set next-transaction-id (+ transaction-id u1))
    (var-set total-energy-traded (+ (var-get total-energy-traded) energy-amount))
    (var-set total-transactions (+ (var-get total-transactions) u1))
    
    (ok transaction-id)
  )
)

;; Update energy producer pricing
(define-public (update-producer-pricing (producer-id uint) (new-price-per-kwh uint))
  (let
    (
      (producer (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get owner producer)) ERR-UNAUTHORIZED)
    (asserts! (and (> new-price-per-kwh u0) (<= new-price-per-kwh MAX-PRICE-PER-KWH)) ERR-INVALID-PRICE)
    
    (map-set energy-producers
      { producer-id: producer-id }
      (merge producer { price-per-kwh: new-price-per-kwh })
    )
    
    (ok true)
  )
)

;; Transfer REC certificate
(define-public (transfer-rec-certificate (rec-id uint) (new-owner principal))
  (let
    (
      (certificate (unwrap! (map-get? rec-certificates { rec-id: rec-id }) ERR-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get current-owner certificate)) ERR-UNAUTHORIZED)
    (asserts! (not (get is-transferred certificate)) ERR-INVALID-INPUT)
    
    (map-set rec-certificates
      { rec-id: rec-id }
      (merge certificate {
        current-owner: new-owner,
        is-transferred: true
      })
    )
    
    (ok true)
  )
)

;; Read-only Functions

;; Get energy producer information
(define-read-only (get-energy-producer (producer-id uint))
  (map-get? energy-producers { producer-id: producer-id })
)

;; Get energy consumer information
(define-read-only (get-energy-consumer (consumer principal))
  (map-get? energy-consumers { consumer: consumer })
)

;; Get energy listing
(define-read-only (get-energy-listing (listing-id uint))
  (map-get? energy-listings { listing-id: listing-id })
)

;; Get energy transaction
(define-read-only (get-energy-transaction (transaction-id uint))
  (map-get? energy-transactions { transaction-id: transaction-id })
)

;; Get REC certificate
(define-read-only (get-rec-certificate (rec-id uint))
  (map-get? rec-certificates { rec-id: rec-id })
)

;; Get producer balance
(define-read-only (get-producer-balance (producer principal))
  (default-to { balance: u0 } (map-get? producer-balances { producer: producer }))
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  (ok {
    total-energy-traded: (var-get total-energy-traded),
    total-transactions: (var-get total-transactions),
    total-producers: (- (var-get next-producer-id) u1),
    total-listings: (- (var-get next-listing-id) u1),
    total-rec-certificates: (- (var-get next-rec-id) u1)
  })
)

;; Get available energy listings (simplified view)
(define-read-only (get-available-listings-summary)
  (ok {
    total-available-listings: (- (var-get next-listing-id) u1),
    platform-active: true
  })
)
