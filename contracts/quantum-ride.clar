;; QuantumRide Smart Contract
;; A decentralized ride-sharing platform built on the Stacks blockchain
;; This contract manages ride requests, driver-passenger matching, payments, and reputation

;; =========================================================================
;; Error constants
;; =========================================================================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-RIDE-NOT-FOUND (err u101))
(define-constant ERR-INSUFFICIENT-FUNDS (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-INVALID-STATE (err u104))
(define-constant ERR-INVALID-RIDER (err u105))
(define-constant ERR-INVALID-DRIVER (err u106))
(define-constant ERR-ALREADY-RATED (err u107))
(define-constant ERR-INVALID-RATING (err u108))
(define-constant ERR-CANNOT-CANCEL (err u109))
(define-constant ERR-RIDE-NOT-COMPLETED (err u110))
(define-constant ERR-INVALID-AMOUNT (err u111))
(define-constant ERR-NOT-IN-PROGRESS (err u112))

;; =========================================================================
;; Constants
;; =========================================================================
(define-constant RIDE-STATE-REQUESTED u1)
(define-constant RIDE-STATE-ACCEPTED u2)
(define-constant RIDE-STATE-IN-PROGRESS u3)
(define-constant RIDE-STATE-COMPLETED u4)
(define-constant RIDE-STATE-CANCELED u5)

(define-constant PLATFORM-FEE-PERCENT u5) ;; 5% platform fee
(define-constant RATING-MIN u1)
(define-constant RATING-MAX u5)
(define-constant CONTRACT-OWNER tx-sender)

;; =========================================================================
;; Data maps and variables
;; =========================================================================

;; Ride data structure
(define-map rides
  { ride-id: uint }
  {
    passenger: principal,
    driver: (optional principal),
    pickup-location: (string-ascii 100),
    destination: (string-ascii 100),
    fare-amount: uint,
    state: uint,
    created-at: uint,
    accepted-at: (optional uint),
    completed-at: (optional uint)
  }
)

;; Tracks the next available ride ID
(define-data-var next-ride-id uint u1)

;; User reputation data
(define-map user-reputation
  { user: principal }
  {
    total-rating: uint,
    rating-count: uint,
    average-rating: uint,  ;; Multiplied by 100 for precision (e.g., 4.25 = 425)
    completed-rides: uint
  }
)

;; Tracks if a user has rated a specific ride
(define-map ride-ratings
  { ride-id: uint, rater: principal }
  { has-rated: bool }
)

;; Tracks the total platform fees collected
(define-data-var platform-fees-collected uint u0)

;; =========================================================================
;; Private functions
;; =========================================================================

;; Calculates the platform fee for a given fare amount
(define-private (calculate-platform-fee (fare-amount uint))
  (/ (* fare-amount PLATFORM-FEE-PERCENT) u100)
)

;; Initializes user reputation if not already existing
(define-private (initialize-user-reputation (user principal))
  (match (map-get? user-reputation { user: user })
    existing-data existing-data
    (map-insert user-reputation
      { user: user }
      {
        total-rating: u0,
        rating-count: u0,
        average-rating: u0,
        completed-rides: u0
      }
    )
  )
)

;; Updates user reputation after receiving a new rating
(define-private (update-reputation (user principal) (rating uint))
  (let ((current-rep (default-to 
                        {
                          total-rating: u0,
                          rating-count: u0,
                          average-rating: u0,
                          completed-rides: u0
                        }
                        (map-get? user-reputation { user: user }))))
    (let ((new-total-rating (+ (get total-rating current-rep) rating))
          (new-rating-count (+ (get rating-count current-rep) u1))
          (new-completed-rides (+ (get completed-rides current-rep) u1))
          (new-average-rating (if (> new-rating-count u0)
                                (/ (* new-total-rating u100) new-rating-count)
                                u0)))
      (map-set user-reputation
        { user: user }
        {
          total-rating: new-total-rating,
          rating-count: new-rating-count,
          average-rating: new-average-rating,
          completed-rides: new-completed-rides
        }
      )
    )
  )
)

;; Increments the completed ride count for a user
(define-private (increment-completed-rides (user principal))
  (let ((current-rep (default-to 
                       {
                         total-rating: u0,
                         rating-count: u0,
                         average-rating: u0,
                         completed-rides: u0
                       }
                       (map-get? user-reputation { user: user }))))
    (map-set user-reputation
      { user: user }
      (merge current-rep { completed-rides: (+ (get completed-rides current-rep) u1) })
    )
  )
)

;; Get the next ride ID and increment the counter
(define-private (get-and-increment-ride-id)
  (let ((current-id (var-get next-ride-id)))
    (var-set next-ride-id (+ current-id u1))
    current-id
  )
)

;; Transfer STX with error handling
(define-private (transfer-stx (amount uint) (recipient principal))
  (if (> amount u0)
      (stx-transfer? amount tx-sender recipient)
      (ok true) ;; If amount is 0, just return success
  )
)

;; =========================================================================
;; Read-only functions
;; =========================================================================

;; Get details of a specific ride
(define-read-only (get-ride (ride-id uint))
  (map-get? rides { ride-id: ride-id })
)

;; Get a user's reputation
(define-read-only (get-user-reputation (user principal))
  (default-to
    {
      total-rating: u0,
      rating-count: u0,
      average-rating: u0,
      completed-rides: u0
    }
    (map-get? user-reputation { user: user })
  )
)

;; Check if a user has already rated a ride
(define-read-only (has-rated-ride (ride-id uint) (user principal))
  (default-to
    { has-rated: false }
    (map-get? ride-ratings { ride-id: ride-id, rater: user })
  )
)

;; Get total platform fees collected
(define-read-only (get-platform-fees)
  (var-get platform-fees-collected)
)

;; =========================================================================
;; Public functions
;; =========================================================================

;; Create a new ride request
(define-public (request-ride (pickup-location (string-ascii 100)) 
                            (destination (string-ascii 100)) 
                            (fare-amount uint))
  (let ((ride-id (get-and-increment-ride-id))
        (block-height (stx-get-height)))
    
    ;; Validate inputs
    (asserts! (> fare-amount u0) ERR-INVALID-AMOUNT)
    
    ;; Check if user has enough funds and lock the payment
    (asserts! (>= (stx-get-balance tx-sender) fare-amount) ERR-INSUFFICIENT-FUNDS)
    
    ;; Initialize user reputation if needed
    (initialize-user-reputation tx-sender)
    
    ;; Create the ride request
    (map-set rides
      { ride-id: ride-id }
      {
        passenger: tx-sender,
        driver: none,
        pickup-location: pickup-location,
        destination: destination,
        fare-amount: fare-amount,
        state: RIDE-STATE-REQUESTED,
        created-at: block-height,
        accepted-at: none,
        completed-at: none
      }
    )
    
    ;; Reserve the funds by transferring to contract
    (match (stx-transfer? fare-amount tx-sender (as-contract tx-sender))
      success (ok ride-id)
      error (err error)
    )
  )
)

;; Accept a ride request (for drivers)
(define-public (accept-ride (ride-id uint))
  (let ((ride (unwrap! (get-ride ride-id) ERR-RIDE-NOT-FOUND))
        (block-height (stx-get-height)))
    
    ;; Ensure ride is in requested state
    (asserts! (is-eq (get state ride) RIDE-STATE-REQUESTED) ERR-INVALID-STATE)
    
    ;; Ensure driver is not the passenger
    (asserts! (not (is-eq tx-sender (get passenger ride))) ERR-INVALID-DRIVER)
    
    ;; Initialize driver reputation if needed
    (initialize-user-reputation tx-sender)
    
    ;; Update the ride with driver info
    (map-set rides
      { ride-id: ride-id }
      (merge ride {
        driver: (some tx-sender),
        state: RIDE-STATE-ACCEPTED,
        accepted-at: (some block-height)
      })
    )
    
    (ok true)
  )
)

;; Start a ride (driver confirms pickup)
(define-public (start-ride (ride-id uint))
  (let ((ride (unwrap! (get-ride ride-id) ERR-RIDE-NOT-FOUND)))
    
    ;; Ensure ride is in accepted state
    (asserts! (is-eq (get state ride) RIDE-STATE-ACCEPTED) ERR-INVALID-STATE)
    
    ;; Ensure caller is the assigned driver
    (asserts! (is-eq (some tx-sender) (get driver ride)) ERR-NOT-AUTHORIZED)
    
    ;; Update ride status to in progress
    (map-set rides
      { ride-id: ride-id }
      (merge ride { state: RIDE-STATE-IN-PROGRESS })
    )
    
    (ok true)
  )
)

;; Complete a ride
(define-public (complete-ride (ride-id uint))
  (let ((ride (unwrap! (get-ride ride-id) ERR-RIDE-NOT-FOUND))
        (block-height (stx-get-height)))
    
    ;; Ensure ride is in progress
    (asserts! (is-eq (get state ride) RIDE-STATE-IN-PROGRESS) ERR-NOT-IN-PROGRESS)
    
    ;; Ensure caller is the assigned driver
    (asserts! (is-eq (some tx-sender) (get driver ride)) ERR-NOT-AUTHORIZED)
    
    ;; Update ride to completed
    (map-set rides
      { ride-id: ride-id }
      (merge ride {
        state: RIDE-STATE-COMPLETED,
        completed-at: (some block-height)
      })
    )
    
    ;; Update completed rides count for both parties
    (increment-completed-rides (get passenger ride))
    (increment-completed-rides tx-sender)
    
    ;; Calculate payment breakdown
    (let ((fare-amount (get fare-amount ride))
          (platform-fee (calculate-platform-fee fare-amount))
          (driver-amount (- fare-amount platform-fee))
          (driver (unwrap! (get driver ride) ERR-INVALID-DRIVER)))
      
      ;; Update platform fees
      (var-set platform-fees-collected (+ (var-get platform-fees-collected) platform-fee))
      
      ;; Transfer fare to driver (minus platform fee)
      (as-contract (stx-transfer? driver-amount (as-contract tx-sender) driver))
    )
    
    (ok true)
  )
)

;; Rate a completed ride
(define-public (rate-ride (ride-id uint) (rating uint))
  (let ((ride (unwrap! (get-ride ride-id) ERR-RIDE-NOT-FOUND))
        (has-rated (get has-rated (has-rated-ride ride-id tx-sender))))
    
    ;; Ensure ride is completed
    (asserts! (is-eq (get state ride) RIDE-STATE-COMPLETED) ERR-RIDE-NOT-COMPLETED)
    
    ;; Ensure rating is in valid range
    (asserts! (and (>= rating RATING-MIN) (<= rating RATING-MAX)) ERR-INVALID-RATING)
    
    ;; Ensure user hasn't already rated this ride
    (asserts! (not has-rated) ERR-ALREADY-RATED)
    
    ;; Determine if the rater is passenger or driver
    (if (is-eq tx-sender (get passenger ride))
        ;; Passenger rating the driver
        (let ((driver (unwrap! (get driver ride) ERR-INVALID-DRIVER)))
          ;; Update driver's reputation
          (update-reputation driver rating)
        )
        ;; Driver rating the passenger
        (if (is-eq (some tx-sender) (get driver ride))
            ;; Update passenger's reputation
            (update-reputation (get passenger ride) rating)
            ;; Neither passenger nor driver
            (err ERR-NOT-AUTHORIZED)
        )
    )
    
    ;; Mark that this user has rated the ride
    (map-set ride-ratings
      { ride-id: ride-id, rater: tx-sender }
      { has-rated: true }
    )
    
    (ok true)
  )
)

;; Cancel a ride request (passenger can cancel before it's accepted)
(define-public (cancel-ride (ride-id uint))
  (let ((ride (unwrap! (get-ride ride-id) ERR-RIDE-NOT-FOUND)))
    
    ;; Ensure caller is the passenger
    (asserts! (is-eq tx-sender (get passenger ride)) ERR-NOT-AUTHORIZED)
    
    ;; Ensure ride is still in requested state
    (asserts! (is-eq (get state ride) RIDE-STATE-REQUESTED) ERR-CANNOT-CANCEL)
    
    ;; Update ride state
    (map-set rides
      { ride-id: ride-id }
      (merge ride { state: RIDE-STATE-CANCELED })
    )
    
    ;; Return fare to passenger
    (as-contract (stx-transfer? (get fare-amount ride) (as-contract tx-sender) (get passenger ride)))
    
    (ok true)
  )
)

;; Withdraw platform fees (only contract owner)
(define-public (withdraw-platform-fees (recipient principal))
  (begin
    ;; Ensure caller is contract owner
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    (let ((fees (var-get platform-fees-collected)))
      ;; Ensure there are fees to withdraw
      (asserts! (> fees u0) ERR-INVALID-AMOUNT)
      
      ;; Reset fees collected
      (var-set platform-fees-collected u0)
      
      ;; Transfer fees to recipient
      (as-contract (stx-transfer? fees (as-contract tx-sender) recipient))
    )
    
    (ok true)
  )
)