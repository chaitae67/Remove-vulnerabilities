package com.example.clinic.service;

import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.repository.ProcedureProductRepository;
import java.util.List;
import org.springframework.stereotype.Service;

@Service
public class ProcedureService {

    private final ProcedureProductRepository procedureRepository;

    public ProcedureService(ProcedureProductRepository procedureRepository) {
        this.procedureRepository = procedureRepository;
    }

    public List<ProcedureProduct> findActiveProcedures() {
        return procedureRepository.findByActiveTrueOrderByIdAsc();
    }

    public ProcedureProduct findById(Long id) {
        return procedureRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("시술 상품을 찾을 수 없습니다."));
    }
}
