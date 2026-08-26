package com.example.clinic.repository;

import com.example.clinic.domain.ProcedureProduct;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

public interface ProcedureProductRepository extends JpaRepository<ProcedureProduct, Long> {
    List<ProcedureProduct> findByActiveTrueOrderByIdAsc();
}
