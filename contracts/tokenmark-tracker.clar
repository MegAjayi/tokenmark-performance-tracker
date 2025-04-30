;; tokenmark-tracker
;; 
;; This contract serves as the central hub for the TokenMark platform, handling token registration,
;; data storage, and all analytics functionality. It maintains a registry of tracked tokens, stores
;; historical performance data, and provides comprehensive analytics capabilities.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-TOKEN-NOT-FOUND (err u101))
(define-constant ERR-TOKEN-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-PARAMETERS (err u103))
(define-constant ERR-DATA-PROVIDER-NOT-REGISTERED (err u104))
(define-constant ERR-INVALID-DATE-RANGE (err u105))
(define-constant ERR-ALERT-NOT-FOUND (err u106))
(define-constant ERR-UNAUTHORIZED-DATA-PROVIDER (err u107))

;; Data space definitions

;; Contract administrator
(define-data-var contract-owner principal tx-sender)

;; Token registry - stores metadata for each tracked token
(define-map tokens 
  { token-id: (string-ascii 64) }
  {
    name: (string-ascii 64),
    symbol: (string-ascii 32),
    description: (string-utf8 500),
    registered-by: principal,
    registered-at: uint,
    active: bool,
    token-type: (string-ascii 20), ;; "ft", "nft", etc.
    contract-address: principal
  }
)

;; List of all registered token IDs for enumeration
(define-data-var token-list (list 200 (string-ascii 64)) (list))

;; Authorized data providers who can submit performance data
(define-map data-providers
  { provider: principal }
  {
    approved-at: uint,
    approved-by: principal,
    active: bool,
    name: (string-ascii 64)
  }
)

;; Performance data points for each token
(define-map performance-data
  { 
    token-id: (string-ascii 64),
    timestamp: uint
  }
  {
    price: uint,             ;; in micro-STX
    volume-24h: uint,        ;; in micro-STX
    market-cap: uint,        ;; in micro-STX
    percent-change-24h: int, ;; basis points (e.g., 250 = 2.5%)
    liquidity: uint,         ;; in micro-STX
    reported-by: principal,
    reported-at: uint
  }
)

;; Time indices to quickly find data points for a given token
(define-map time-indices
  { token-id: (string-ascii 64) }
  { timestamps: (list 1000 uint) }
)

;; Performance alerts set by users
(define-map performance-alerts
  {
    alert-id: uint,
    user: principal
  }
  {
    token-id: (string-ascii 64),
    threshold-type: (string-ascii 20), ;; "price-above", "price-below", "percent-change", etc.
    threshold-value: int,
    created-at: uint,
    active: bool,
    last-triggered: (optional uint)
  }
)

;; Counter for alert IDs
(define-data-var next-alert-id uint u1)

;; Private functions

;; Add timestamp to time index for a token
(define-private (add-timestamp-to-index (token-id (string-ascii 64)) (timestamp uint))
  (let (
    (current-indices (default-to { timestamps: (list) } (map-get? time-indices { token-id: token-id })))
    (updated-timestamps (append (get timestamps current-indices) timestamp))
  )
    (map-set time-indices 
      { token-id: token-id }
      { timestamps: updated-timestamps }
    )
    (ok true)
  )
)

;; Verify if principal is a registered and active data provider
(define-private (is-authorized-data-provider (provider principal))
  (let (
    (data-provider (map-get? data-providers { provider: provider }))
  )
    (and 
      (is-some data-provider) 
      (get active (unwrap! data-provider false))
    )
  )
)

;; Check if a token exists and is active
(define-private (is-active-token (token-id (string-ascii 64)))
  (let (
    (token-data (map-get? tokens { token-id: token-id }))
  )
    (and 
      (is-some token-data) 
      (get active (unwrap! token-data false))
    )
  )
)

;; Calculate percentage change between two values
(define-private (calculate-percent-change (old-value uint) (new-value uint))
  (if (is-eq old-value u0)
    ;; If old value is zero, we can't calculate percentage change
    0
    (let (
      (diff (- new-value old-value))
      (ratio (* diff u10000)) ;; Multiply to get basis points
    )
      (/ ratio old-value)
    )
  )
)

;; Find latest data point before the given timestamp
(define-private (find-latest-data-before (token-id (string-ascii 64)) (timestamp uint))
  (let (
    (indices (default-to { timestamps: (list) } (map-get? time-indices { token-id: token-id })))
    (timestamps (get timestamps indices))
    ;; Filter timestamps to get those before the given timestamp and take the last one
    (filtered-timestamps (filter timestamp-before-filter timestamps))
    (latest-timestamp (unwrap! (element-at filtered-timestamps (- (len filtered-timestamps) u1)) u0))
  )
    (if (is-eq latest-timestamp u0)
      none
      (map-get? performance-data { token-id: token-id, timestamp: latest-timestamp })
    )
  )
  (define-private (timestamp-before-filter (ts uint)) (< ts timestamp))
)

;; Read-only functions

;; Get a token's metadata
(define-read-only (get-token-metadata (token-id (string-ascii 64)))
  (map-get? tokens { token-id: token-id })
)

;; Get list of all registered tokens
(define-read-only (get-all-tokens)
  (var-get token-list)
)

;; Get the latest performance data for a token
(define-read-only (get-latest-token-data (token-id (string-ascii 64)))
  (let (
    (indices (default-to { timestamps: (list) } (map-get? time-indices { token-id: token-id })))
    (timestamps (get timestamps indices))
  )
    (if (> (len timestamps) u0)
      (let (
        (latest-timestamp (unwrap! (element-at timestamps (- (len timestamps) u1)) u0))
      )
        (map-get? performance-data { token-id: token-id, timestamp: latest-timestamp })
      )
      none
    )
  )
)

;; Get historical performance data for a token within a time range
(define-read-only (get-token-history (token-id (string-ascii 64)) (start-time uint) (end-time uint) (max-results uint))
  (let (
    (indices (default-to { timestamps: (list) } (map-get? time-indices { token-id: token-id })))
    (all-timestamps (get timestamps indices))
    ;; Filter timestamps to the specified range
    (filtered-timestamps (filter time-range-filter all-timestamps))
    ;; Limit results to max-results, taking most recent if needed
    (result-count (if (> (len filtered-timestamps) max-results) max-results (len filtered-timestamps)))
    (selected-timestamps (if (> (len filtered-timestamps) max-results)
                          (take-right filtered-timestamps max-results)
                          filtered-timestamps))
  )
    (map get-data-point-by-timestamp selected-timestamps)
  )
  (define-private (time-range-filter (ts uint)) (and (>= ts start-time) (<= ts end-time)))
  (define-private (get-data-point-by-timestamp (ts uint)) 
    (default-to 
      {
        price: u0, volume-24h: u0, market-cap: u0, percent-change-24h: 0,
        liquidity: u0, reported-by: tx-sender, reported-at: u0
      } 
      (map-get? performance-data { token-id: token-id, timestamp: ts })
    )
  )
)

;; Check if a data provider is authorized
(define-read-only (is-data-provider (provider principal))
  (is-authorized-data-provider provider)
)

;; Get alerts for a user
(define-read-only (get-user-alerts (user principal))
  (let (
    (alert-id-count (var-get next-alert-id))
    (user-alerts (list))
  )
    (filter-user-alerts user alert-id-count)
  )
)

;; Recursive helper for filtering alerts by user (limited to checking 100 alerts)
(define-private (filter-user-alerts (user principal) (current-id uint))
  (let (
    (max-check u100)
    (results (list))
  )
    (filter-helper user current-id u0 max-check results)
  )
)

(define-private (filter-helper (user principal) (current-id uint) (count uint) (max-check uint) (results (list 100 {alert-id: uint, details: (optional {token-id: (string-ascii 64), threshold-type: (string-ascii 20), threshold-value: int, created-at: uint, active: bool, last-triggered: (optional uint)})})))
  (if (or (is-eq count max-check) (is-eq current-id u0))
    results
    (let (
      (alert-data (map-get? performance-alerts {alert-id: (- current-id u1), user: user}))
      (new-results (if (is-some alert-data)
                     (append results {alert-id: (- current-id u1), details: alert-data})
                     results))
    )
      (filter-helper user (- current-id u1) (+ count u1) max-check new-results)
    )
  )
)

;; Compare performance between two tokens over a time period
(define-read-only (compare-tokens (token-id-1 (string-ascii 64)) (token-id-2 (string-ascii 64)) (start-time uint) (end-time uint))
  (let (
    (token-1-start (find-latest-data-before token-id-1 start-time))
    (token-1-end (find-latest-data-before token-id-1 end-time))
    (token-2-start (find-latest-data-before token-id-2 start-time))
    (token-2-end (find-latest-data-before token-id-2 end-time))
  )
    (if (and (is-some token-1-start) (is-some token-1-end) 
             (is-some token-2-start) (is-some token-2-end))
      (let (
        (token-1-start-price (get price (unwrap! token-1-start u0)))
        (token-1-end-price (get price (unwrap! token-1-end u0)))
        (token-2-start-price (get price (unwrap! token-2-start u0)))
        (token-2-end-price (get price (unwrap! token-2-end u0)))
        (token-1-change (calculate-percent-change token-1-start-price token-1-end-price))
        (token-2-change (calculate-percent-change token-2-start-price token-2-end-price))
      )
        (some {
          token-1-start-price: token-1-start-price,
          token-1-end-price: token-1-end-price,
          token-1-percent-change: token-1-change,
          token-2-start-price: token-2-start-price,
          token-2-end-price: token-2-end-price,
          token-2-percent-change: token-2-change,
          relative-performance: (- token-1-change token-2-change)
        })
      )
      none
    )
  )
)

;; Public functions

;; Register a new token for tracking
(define-public (register-token (token-id (string-ascii 64)) (name (string-ascii 64)) 
                              (symbol (string-ascii 32)) (description (string-utf8 500))
                              (token-type (string-ascii 20)) (contract-address principal))
  (let (
    (existing-token (map-get? tokens { token-id: token-id }))
    (current-list (var-get token-list))
  )
    ;; Check if token already exists
    (asserts! (is-none existing-token) ERR-TOKEN-ALREADY-EXISTS)
    
    ;; Register the token
    (map-set tokens 
      { token-id: token-id }
      {
        name: name,
        symbol: symbol,
        description: description,
        registered-by: tx-sender,
        registered-at: block-height,
        active: true,
        token-type: token-type,
        contract-address: contract-address
      }
    )
    
    ;; Add to token list
    (var-set token-list (append current-list token-id))
    
    ;; Initialize time index for the token
    (map-set time-indices 
      { token-id: token-id }
      { timestamps: (list) }
    )
    
    (ok true)
  )
)

;; Update token metadata
(define-public (update-token-metadata (token-id (string-ascii 64)) (name (string-ascii 64))
                                     (symbol (string-ascii 32)) (description (string-utf8 500)))
  (let (
    (token-data (map-get? tokens { token-id: token-id }))
  )
    ;; Check if token exists
    (asserts! (is-some token-data) ERR-TOKEN-NOT-FOUND)
    (let (
      (unwrapped-data (unwrap! token-data ERR-TOKEN-NOT-FOUND))
    )
      ;; Check if caller is the original registrar or contract owner
      (asserts! (or 
                (is-eq tx-sender (get registered-by unwrapped-data))
                (is-eq tx-sender (var-get contract-owner)))
        ERR-NOT-AUTHORIZED)
        
      ;; Update token metadata
      (map-set tokens 
        { token-id: token-id }
        (merge unwrapped-data {
          name: name,
          symbol: symbol,
          description: description
        })
      )
      
      (ok true)
    )
  )
)

;; Deactivate a token
(define-public (deactivate-token (token-id (string-ascii 64)))
  (let (
    (token-data (map-get? tokens { token-id: token-id }))
  )
    ;; Check if token exists
    (asserts! (is-some token-data) ERR-TOKEN-NOT-FOUND)
    (let (
      (unwrapped-data (unwrap! token-data ERR-TOKEN-NOT-FOUND))
    )
      ;; Check if caller is the original registrar or contract owner
      (asserts! (or 
                (is-eq tx-sender (get registered-by unwrapped-data))
                (is-eq tx-sender (var-get contract-owner)))
        ERR-NOT-AUTHORIZED)
        
      ;; Update token active status
      (map-set tokens 
        { token-id: token-id }
        (merge unwrapped-data { active: false })
      )
      
      (ok true)
    )
  )
)

;; Add or update a data provider
(define-public (set-data-provider (provider principal) (provider-name (string-ascii 64)) (active bool))
  ;; Only contract owner can manage data providers
  (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
  
  (map-set data-providers
    { provider: provider }
    {
      approved-at: block-height,
      approved-by: tx-sender,
      active: active,
      name: provider-name
    }
  )
  
  (ok true)
)

;; Submit performance data for a token
(define-public (submit-performance-data (token-id (string-ascii 64)) (timestamp uint)
                                       (price uint) (volume-24h uint) (market-cap uint)
                                       (percent-change-24h int) (liquidity uint))
  (let (
    (token-exists (is-active-token token-id))
  )
    ;; Check if token exists and is active
    (asserts! token-exists ERR-TOKEN-NOT-FOUND)
    
    ;; Check if caller is an authorized data provider
    (asserts! (is-authorized-data-provider tx-sender) ERR-UNAUTHORIZED-DATA-PROVIDER)
    
    ;; Store the performance data
    (map-set performance-data
      { 
        token-id: token-id,
        timestamp: timestamp
      }
      {
        price: price,
        volume-24h: volume-24h,
        market-cap: market-cap,
        percent-change-24h: percent-change-24h,
        liquidity: liquidity,
        reported-by: tx-sender,
        reported-at: block-height
      }
    )
    
    ;; Update the time index
    (add-timestamp-to-index token-id timestamp)
    
    ;; Check for alerts that should be triggered
    (check-alerts token-id price percent-change-24h)
    
    (ok true)
  )
)

;; Create a new performance alert
(define-public (create-alert (token-id (string-ascii 64)) (threshold-type (string-ascii 20)) (threshold-value int))
  (let (
    (token-exists (is-active-token token-id))
    (alert-id (var-get next-alert-id))
  )
    ;; Check if token exists and is active
    (asserts! token-exists ERR-TOKEN-NOT-FOUND)
    
    ;; Create the alert
    (map-set performance-alerts
      {
        alert-id: alert-id,
        user: tx-sender
      }
      {
        token-id: token-id,
        threshold-type: threshold-type,
        threshold-value: threshold-value,
        created-at: block-height,
        active: true,
        last-triggered: none
      }
    )
    
    ;; Increment alert ID counter
    (var-set next-alert-id (+ alert-id u1))
    
    (ok alert-id)
  )
)

;; Deactivate an alert
(define-public (deactivate-alert (alert-id uint))
  (let (
    (alert-data (map-get? performance-alerts { alert-id: alert-id, user: tx-sender }))
  )
    ;; Check if alert exists
    (asserts! (is-some alert-data) ERR-ALERT-NOT-FOUND)
    (let (
      (unwrapped-data (unwrap! alert-data ERR-ALERT-NOT-FOUND))
    )
      ;; Update alert active status
      (map-set performance-alerts 
        { alert-id: alert-id, user: tx-sender }
        (merge unwrapped-data { active: false })
      )
      
      (ok true)
    )
  )
)

;; Transfer contract ownership
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Check if any alerts should be triggered by new data
(define-private (check-alerts (token-id (string-ascii 64)) (price uint) (percent-change int))
  ;; This would be implemented to check all alerts for the token
  ;; and update them if their conditions are met
  ;; In a real implementation, would need pagination or other mechanism
  ;; as we can't iterate through all alerts in Clarity
  (ok true)
)