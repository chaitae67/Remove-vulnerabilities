CREATE TABLE app_user (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    username VARCHAR2(50 CHAR) NOT NULL,
    password VARCHAR2(255 CHAR) NOT NULL,
    name VARCHAR2(50 CHAR) NOT NULL,
    email VARCHAR2(120 CHAR) NOT NULL,
    phone VARCHAR2(30 CHAR),
    role VARCHAR2(20 CHAR) DEFAULT 'USER' NOT NULL,
    point_balance NUMBER(10) DEFAULT 0 NOT NULL,
    withdrawn NUMBER(1) DEFAULT 0 NOT NULL,
    withdrawn_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_app_user PRIMARY KEY (id),
    CONSTRAINT uk_app_user_username UNIQUE (username),
    CONSTRAINT uk_app_user_email UNIQUE (email),
    CONSTRAINT ck_app_user_role CHECK (role IN ('USER', 'ADMIN')),
    CONSTRAINT ck_app_user_withdrawn CHECK (withdrawn IN (0, 1))
);


CREATE TABLE procedure_product (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    name VARCHAR2(80 CHAR) NOT NULL,
    category VARCHAR2(40 CHAR) NOT NULL,
    summary VARCHAR2(160 CHAR) NOT NULL,
    description VARCHAR2(1000 CHAR) NOT NULL,
    price NUMBER(12, 0) NOT NULL,
    active NUMBER(1) DEFAULT 1 NOT NULL,

    CONSTRAINT pk_procedure_product PRIMARY KEY (id),
    CONSTRAINT ck_procedure_active CHECK (active IN (0, 1))
);


CREATE TABLE coupon (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    code VARCHAR2(40 CHAR) NOT NULL,
    name VARCHAR2(100 CHAR) NOT NULL,
    discount_amount NUMBER(10) NOT NULL,
    active NUMBER(1) DEFAULT 1 NOT NULL,
    expires_at DATE,

    CONSTRAINT pk_coupon PRIMARY KEY (id),
    CONSTRAINT uk_coupon_code UNIQUE (code),
    CONSTRAINT ck_coupon_active CHECK (active IN (0, 1))
);


CREATE TABLE notice (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    title VARCHAR2(160 CHAR) NOT NULL,
    content VARCHAR2(4000 CHAR) NOT NULL,
    author_id NUMBER(19) NOT NULL,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at TIMESTAMP,

    CONSTRAINT pk_notice PRIMARY KEY (id),
    CONSTRAINT fk_notice_author
        FOREIGN KEY (author_id) REFERENCES app_user (id)
);


CREATE TABLE qna_post (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    title VARCHAR2(160 CHAR) NOT NULL,
    content VARCHAR2(4000 CHAR) NOT NULL,
    writer_id NUMBER(19) NOT NULL,
    phone VARCHAR2(30 CHAR),
    private_post NUMBER(1) DEFAULT 0 NOT NULL,
    answered NUMBER(1) DEFAULT 0 NOT NULL,
    answer VARCHAR2(4000 CHAR),
    answered_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_qna_post PRIMARY KEY (id),
    CONSTRAINT fk_qna_writer
        FOREIGN KEY (writer_id) REFERENCES app_user (id),
    CONSTRAINT ck_qna_private CHECK (private_post IN (0, 1)),
    CONSTRAINT ck_qna_answered CHECK (answered IN (0, 1))
);


CREATE TABLE qna_attachment (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    original_filename VARCHAR2(255 CHAR) NOT NULL,
    stored_filename VARCHAR2(255 CHAR) NOT NULL,
    content_type VARCHAR2(120 CHAR),
    file_size NUMBER(19) NOT NULL,
    post_id NUMBER(19) NOT NULL,

    CONSTRAINT pk_qna_attachment PRIMARY KEY (id),
    CONSTRAINT fk_qna_attachment_post
        FOREIGN KEY (post_id) REFERENCES qna_post (id)
);


CREATE TABLE review (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    title VARCHAR2(160 CHAR) NOT NULL,
    content VARCHAR2(4000 CHAR) NOT NULL,
    rating NUMBER(1) NOT NULL,
    writer_id NUMBER(19) NOT NULL,
    procedure_product_id NUMBER(19),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at TIMESTAMP,

    CONSTRAINT pk_review PRIMARY KEY (id),
    CONSTRAINT fk_review_writer
        FOREIGN KEY (writer_id) REFERENCES app_user (id),
    CONSTRAINT fk_review_product
        FOREIGN KEY (procedure_product_id) REFERENCES procedure_product (id),
    CONSTRAINT ck_review_rating CHECK (rating BETWEEN 1 AND 5)
);


CREATE TABLE review_attachment (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    original_filename VARCHAR2(255 CHAR) NOT NULL,
    stored_filename VARCHAR2(255 CHAR) NOT NULL,
    content_type VARCHAR2(120 CHAR),
    file_size NUMBER(19) NOT NULL,
    review_id NUMBER(19) NOT NULL,

    CONSTRAINT pk_review_attachment PRIMARY KEY (id),
    CONSTRAINT fk_review_attachment_review
        FOREIGN KEY (review_id) REFERENCES review (id)
);


CREATE TABLE payment_order (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    order_number VARCHAR2(40 CHAR) NOT NULL,
    buyer_id NUMBER(19) NOT NULL,
    procedure_product_id NUMBER(19) NOT NULL,
    amount NUMBER(12, 0) NOT NULL,
    original_amount NUMBER(12, 0) NOT NULL,
    coupon_discount NUMBER(10) DEFAULT 0 NOT NULL,
    points_used NUMBER(10) DEFAULT 0 NOT NULL,
    earned_points NUMBER(10) DEFAULT 0 NOT NULL,
    coupon_id NUMBER(19),
    status VARCHAR2(20 CHAR) DEFAULT 'READY' NOT NULL,
    method VARCHAR2(40 CHAR),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    paid_at TIMESTAMP,

    CONSTRAINT pk_payment_order PRIMARY KEY (id),
    CONSTRAINT uk_payment_order_no UNIQUE (order_number),
    CONSTRAINT fk_payment_buyer
        FOREIGN KEY (buyer_id) REFERENCES app_user (id),
    CONSTRAINT fk_payment_product
        FOREIGN KEY (procedure_product_id) REFERENCES procedure_product (id),
    CONSTRAINT fk_payment_coupon
        FOREIGN KEY (coupon_id) REFERENCES coupon (id),
    CONSTRAINT ck_payment_status
        CHECK (status IN ('READY', 'PAID', 'CANCELED'))
);


CREATE TABLE quick_consultation (
    id NUMBER(19) GENERATED ALWAYS AS IDENTITY,
    name VARCHAR2(40 CHAR) NOT NULL,
    phone VARCHAR2(30 CHAR) NOT NULL,
    area VARCHAR2(60 CHAR) NOT NULL,
    preferred_contact VARCHAR2(30 CHAR) NOT NULL,
    message VARCHAR2(1000 CHAR),
    privacy_agreed NUMBER(1) DEFAULT 1 NOT NULL,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT pk_quick_consultation PRIMARY KEY (id),
    CONSTRAINT ck_consult_privacy CHECK (privacy_agreed IN (0, 1))
);


CREATE INDEX ix_review_created_at
    ON review (created_at DESC);

CREATE INDEX ix_notice_created_at
    ON notice (created_at DESC);

CREATE INDEX ix_qna_created_at
    ON qna_post (created_at DESC);

CREATE INDEX ix_payment_created_at
    ON payment_order (created_at DESC);

CREATE INDEX ix_consult_created_at
    ON quick_consultation (created_at DESC);
