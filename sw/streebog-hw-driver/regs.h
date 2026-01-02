// Created with Corsair v1.0.4
#ifndef __REGS_H
#define __REGS_H

#define __I  volatile const // 'read only' permissions
#define __O  volatile       // 'write only' permissions
#define __IO volatile       // 'read / write' permissions


#ifdef __cplusplus
#include <cstdint>
extern "C" {
#else
#include <stdint.h>
#endif

#define CSR_BASE_ADDR 0x0

// MODE - Определяет размер выходного хеша (256/512 бит)
#define CSR_MODE_ADDR 0x0
#define CSR_MODE_RESET 0x1
typedef struct {
    uint32_t MODE_BIT : 1; // Бит режима (1=512, 0=256)
    uint32_t : 31; // reserved
} csr_mode_t;

// MODE.MODE_BIT - Бит режима (1=512, 0=256)
#define CSR_MODE_MODE_BIT_WIDTH 1
#define CSR_MODE_MODE_BIT_LSB 0
#define CSR_MODE_MODE_BIT_MASK 0x1
#define CSR_MODE_MODE_BIT_RESET 0x1

// TOTAL_NUM_TRANS - Defines num of tlast asserts from xdma
#define CSR_TOTAL_NUM_TRANS_ADDR 0x4
#define CSR_TOTAL_NUM_TRANS_RESET 0x0
typedef struct {
    uint32_t NUM_TRANS_VAL : 32; // Value from host
} csr_total_num_trans_t;

// TOTAL_NUM_TRANS.NUM_TRANS_VAL - Value from host
#define CSR_TOTAL_NUM_TRANS_NUM_TRANS_VAL_WIDTH 32
#define CSR_TOTAL_NUM_TRANS_NUM_TRANS_VAL_LSB 0
#define CSR_TOTAL_NUM_TRANS_NUM_TRANS_VAL_MASK 0xffffffff
#define CSR_TOTAL_NUM_TRANS_NUM_TRANS_VAL_RESET 0x0

// RECV_NUM_TRANS - Tlast assert counter
#define CSR_RECV_NUM_TRANS_ADDR 0x8
#define CSR_RECV_NUM_TRANS_RESET 0x0
typedef struct {
    uint32_t NUM_TRANS_RECV : 32; // Keep num of received transactions
} csr_recv_num_trans_t;

// RECV_NUM_TRANS.NUM_TRANS_RECV - Keep num of received transactions
#define CSR_RECV_NUM_TRANS_NUM_TRANS_RECV_WIDTH 32
#define CSR_RECV_NUM_TRANS_NUM_TRANS_RECV_LSB 0
#define CSR_RECV_NUM_TRANS_NUM_TRANS_RECV_MASK 0xffffffff
#define CSR_RECV_NUM_TRANS_NUM_TRANS_RECV_RESET 0x0


// Register map structure
typedef struct {
    union {
        __IO uint32_t MODE; // Определяет размер выходного хеша (256/512 бит)
        __IO csr_mode_t MODE_bf; // Bit access for MODE register
    };
    union {
        __O uint32_t TOTAL_NUM_TRANS; // Defines num of tlast asserts from xdma
        __O csr_total_num_trans_t TOTAL_NUM_TRANS_bf; // Bit access for TOTAL_NUM_TRANS register
    };
    union {
        __I uint32_t RECV_NUM_TRANS; // Tlast assert counter
        __I csr_recv_num_trans_t RECV_NUM_TRANS_bf; // Bit access for RECV_NUM_TRANS register
    };
} csr_t;

#define CSR ((csr_t*)(CSR_BASE_ADDR))

#ifdef __cplusplus
}
#endif

#endif /* __REGS_H */
