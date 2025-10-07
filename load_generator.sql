-- ============================================================================
-- GENERATOR OBCIĄŻENIA DLA POSTGRESQL - LOAD TESTING - PEŁNA WERSJA
-- Kompletny system do testowania wydajności bazy danych
-- ============================================================================

-- Włączenie rozszerzeń
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Tabele
DROP TABLE IF EXISTS test_reviews CASCADE;
DROP TABLE IF EXISTS test_inventory CASCADE;
DROP TABLE IF EXISTS test_transactions CASCADE;
DROP TABLE IF EXISTS test_activity_logs CASCADE;
DROP TABLE IF EXISTS test_order_items CASCADE;
DROP TABLE IF EXISTS test_orders CASCADE;
DROP TABLE IF EXISTS test_products CASCADE;
DROP TABLE IF EXISTS test_categories CASCADE;
DROP TABLE IF EXISTS test_users CASCADE;

CREATE TABLE test_users (
    user_id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4(),
    username VARCHAR(50) NOT NULL,
    email VARCHAR(100) NOT NULL,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    phone VARCHAR(20),
    date_of_birth DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP,
    login_count INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active',
    country VARCHAR(50),
    city VARCHAR(100),
    address TEXT,
    postal_code VARCHAR(10),
    balance DECIMAL(12,2) DEFAULT 0,
    credit_limit DECIMAL(12,2) DEFAULT 1000,
    preferences JSONB,
    tags TEXT[]
);

CREATE TABLE test_products (
    product_id SERIAL PRIMARY KEY,
    sku VARCHAR(50) UNIQUE NOT NULL,
    product_name VARCHAR(200) NOT NULL,
    category VARCHAR(50),
    subcategory VARCHAR(50),
    brand VARCHAR(100),
    price DECIMAL(10,2),
    cost DECIMAL(10,2),
    stock_quantity INTEGER DEFAULT 0,
    reorder_level INTEGER DEFAULT 10,
    weight_kg DECIMAL(8,3),
    dimensions_cm VARCHAR(50),
    description TEXT,
    long_description TEXT,
    features JSONB,
    tags TEXT[],
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    rating DECIMAL(3,2),
    review_count INTEGER DEFAULT 0
);

CREATE TABLE test_orders (
    order_id SERIAL PRIMARY KEY,
    order_number VARCHAR(50) UNIQUE NOT NULL,
    user_id INTEGER REFERENCES test_users(user_id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    shipped_date TIMESTAMP,
    delivery_date TIMESTAMP,
    total_amount DECIMAL(12,2),
    tax_amount DECIMAL(12,2),
    shipping_cost DECIMAL(10,2),
    discount_amount DECIMAL(10,2),
    final_amount DECIMAL(12,2),
    status VARCHAR(30) DEFAULT 'pending',
    payment_method VARCHAR(30),
    payment_status VARCHAR(30),
    shipping_address TEXT,
    billing_address TEXT,
    tracking_number VARCHAR(100),
    notes TEXT,
    metadata JSONB
);

CREATE TABLE test_order_items (
    item_id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES test_orders(order_id) ON DELETE CASCADE,
    product_id INTEGER REFERENCES test_products(product_id),
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(10,2),
    discount_pct DECIMAL(5,2) DEFAULT 0,
    tax_pct DECIMAL(5,2) DEFAULT 0,
    line_total DECIMAL(12,2),
    notes TEXT
);

CREATE TABLE test_activity_logs (
    log_id SERIAL PRIMARY KEY,
    user_id INTEGER,
    session_id UUID,
    action VARCHAR(100),
    entity_type VARCHAR(50),
    entity_id INTEGER,
    log_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ip_address INET,
    user_agent TEXT,
    details JSONB,
    execution_time_ms INTEGER
);

CREATE TABLE test_transactions (
    transaction_id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES test_users(user_id),
    order_id INTEGER REFERENCES test_orders(order_id),
    transaction_type VARCHAR(30),
    amount DECIMAL(12,2),
    currency VARCHAR(3) DEFAULT 'PLN',
    status VARCHAR(30),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    reference_number VARCHAR(100),
    description TEXT,
    metadata JSONB
);

CREATE TABLE test_categories (
    category_id SERIAL PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL,
    parent_category_id INTEGER REFERENCES test_categories(category_id),
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    sort_order INTEGER
);

CREATE TABLE test_inventory (
    inventory_id SERIAL PRIMARY KEY,
    product_id INTEGER REFERENCES test_products(product_id),
    warehouse_id INTEGER,
    quantity INTEGER DEFAULT 0,
    reserved_quantity INTEGER DEFAULT 0,
    available_quantity INTEGER GENERATED ALWAYS AS (quantity - reserved_quantity) STORED,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    location VARCHAR(50)
);

CREATE TABLE test_reviews (
    review_id SERIAL PRIMARY KEY,
    product_id INTEGER REFERENCES test_products(product_id),
    user_id INTEGER REFERENCES test_users(user_id),
    rating INTEGER CHECK (rating >= 1 AND rating <= 5),
    review_title VARCHAR(200),
    review_text TEXT,
    is_verified_purchase BOOLEAN DEFAULT false,
    helpful_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- FUNKCJE POMOCNICZE
-- ============================================================================

CREATE OR REPLACE FUNCTION random_email(prefix TEXT DEFAULT 'user')
RETURNS TEXT
LANGUAGE plpgsql
AS $function$
DECLARE
    domains TEXT[] := ARRAY['gmail.com', 'yahoo.com', 'outlook.com', 'example.com'];
BEGIN
    RETURN prefix || floor(random() * 1000000)::TEXT || '@' || domains[floor(random() * 4 + 1)];
END;
$function$;

CREATE OR REPLACE FUNCTION random_first_name()
RETURNS TEXT
LANGUAGE plpgsql
AS $function$
DECLARE
    names TEXT[] := ARRAY['Jan', 'Anna', 'Piotr', 'Maria', 'Krzysztof', 'Katarzyna', 
                          'Andrzej', 'Magdalena', 'Tomasz', 'Agnieszka', 'Paweł', 
                          'Barbara', 'Michał', 'Joanna', 'Marcin', 'Ewa'];
BEGIN
    RETURN names[floor(random() * 16 + 1)];
END;
$function$;

CREATE OR REPLACE FUNCTION random_last_name()
RETURNS TEXT
LANGUAGE plpgsql
AS $function$
DECLARE
    names TEXT[] := ARRAY['Kowalski', 'Nowak', 'Wiśniewski', 'Wójcik', 'Kowalczyk', 
                          'Kamiński', 'Lewandowski', 'Zieliński', 'Szymański', 
                          'Woźniak', 'Dąbrowski', 'Kozłowski'];
BEGIN
    RETURN names[floor(random() * 12 + 1)];
END;
$function$;

CREATE OR REPLACE FUNCTION random_city()
RETURNS TEXT
LANGUAGE plpgsql
AS $function$
DECLARE
    cities TEXT[] := ARRAY['Warszawa', 'Kraków', 'Wrocław', 'Poznań', 'Gdańsk', 
                           'Szczecin', 'Bydgoszcz', 'Lublin', 'Katowice', 'Białystok',
                           'Gdynia', 'Częstochowa', 'Radom', 'Sosnowiec', 'Toruń'];
BEGIN
    RETURN cities[floor(random() * 15 + 1)];
END;
$function$;

-- ============================================================================
-- GENEROWANIE DANYCH
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_test_users(num_users INTEGER DEFAULT 10000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
    batch_size INTEGER := 1000;
BEGIN
    RAISE NOTICE 'Generating % users...', num_users;
    
    FOR i IN 1..num_users BY batch_size LOOP
        INSERT INTO test_users (
            username, email, first_name, last_name, phone, date_of_birth,
            last_login, login_count, status, country, city, address, 
            postal_code, balance, credit_limit, preferences, tags
        )
        SELECT
            'user_' || (i + j),
            random_email('user' || (i + j)),
            random_first_name(),
            random_last_name(),
            '+48' || (100000000 + floor(random() * 900000000))::TEXT,
            CURRENT_DATE - (random() * 365 * 50)::INTEGER,
            CURRENT_TIMESTAMP - (random() * INTERVAL '365 days'),
            floor(random() * 1000)::INTEGER,
            CASE 
                WHEN random() < 0.85 THEN 'active'
                WHEN random() < 0.95 THEN 'inactive'
                ELSE 'suspended'
            END,
            CASE 
                WHEN random() < 0.8 THEN 'Poland'
                WHEN random() < 0.9 THEN 'Germany'
                ELSE 'United Kingdom'
            END,
            random_city(),
            'ul. Testowa ' || floor(random() * 200 + 1)::TEXT,
            (10000 + floor(random() * 90000))::TEXT,
            (random() * 10000)::DECIMAL(12,2),
            (1000 + random() * 49000)::DECIMAL(12,2),
            jsonb_build_object(
                'newsletter', random() < 0.5,
                'theme', CASE WHEN random() < 0.5 THEN 'dark' ELSE 'light' END,
                'language', 'pl'
            ),
            ARRAY['customer', CASE WHEN random() < 0.1 THEN 'vip' ELSE 'regular' END]
        FROM generate_series(0, LEAST(batch_size - 1, num_users - i)) AS j;
        
        IF i % 5000 = 0 THEN
            RAISE NOTICE 'Generated % users...', i;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Users generation completed: % rows', num_users;
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_categories()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO test_categories (category_name, parent_category_id, description, sort_order) VALUES
    ('Elektronika', NULL, 'Produkty elektroniczne', 1),
    ('Odzież', NULL, 'Odzież i akcesoria', 2),
    ('Dom i Ogród', NULL, 'Produkty do domu', 3),
    ('Sport', NULL, 'Artykuły sportowe', 4),
    ('Książki', NULL, 'Książki i multimedia', 5);
    
    INSERT INTO test_categories (category_name, parent_category_id, description, sort_order)
    SELECT 
        sub.name,
        parent.category_id,
        'Podkategoria: ' || sub.name,
        sub.sort_order
    FROM (VALUES 
        ('Komputery', 1, 1), ('Telefony', 1, 2), ('Audio', 1, 3),
        ('Damska', 2, 1), ('Męska', 2, 2), ('Dziecięca', 2, 3),
        ('Meble', 3, 1), ('Dekoracje', 3, 2), ('Narzędzia', 3, 3),
        ('Fitness', 4, 1), ('Outdoor', 4, 2), ('Rowery', 4, 3),
        ('Literatura', 5, 1), ('Nauka', 5, 2), ('Hobby', 5, 3)
    ) AS sub(name, parent_id, sort_order)
    JOIN test_categories parent ON parent.category_id = sub.parent_id;
    
    RAISE NOTICE 'Categories generated';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_products(num_products INTEGER DEFAULT 5000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
    cat_arr TEXT[] := ARRAY['Elektronika', 'Odzież', 'Dom i Ogród', 'Sport', 'Książki'];
    brand_arr TEXT[] := ARRAY['Samsung', 'Apple', 'Sony', 'LG', 'Dell', 'HP', 'Adidas', 'Nike', 'IKEA', 'Bosch'];
BEGIN
    RAISE NOTICE 'Generating % products...', num_products;
    
    FOR i IN 1..num_products LOOP
        INSERT INTO test_products (
            sku, product_name, category, subcategory, brand, price, cost,
            stock_quantity, reorder_level, weight_kg, description, long_description,
            features, tags, rating, review_count
        )
        VALUES (
            'SKU-' || LPAD(i::TEXT, 8, '0'),
            'Produkt ' || i,
            cat_arr[floor(random() * 5 + 1)],
            'Podkategoria ' || floor(random() * 3 + 1),
            brand_arr[floor(random() * 10 + 1)],
            (random() * 5000 + 10)::DECIMAL(10,2),
            (random() * 3000 + 5)::DECIMAL(10,2),
            floor(random() * 1000)::INTEGER,
            floor(random() * 50 + 5)::INTEGER,
            (random() * 20 + 0.1)::DECIMAL(8,3),
            'Opis produktu ' || i,
            'Długi opis produktu ' || i || '. ' || repeat('Lorem ipsum. ', 10),
            jsonb_build_object('color', 'black', 'warranty_months', 12),
            ARRAY['bestseller', 'new'],
            (random() * 2 + 3)::DECIMAL(3,2),
            floor(random() * 500)::INTEGER
        );
        
        IF i % 1000 = 0 THEN
            RAISE NOTICE 'Generated % products...', i;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Products generation completed';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_orders(num_orders INTEGER DEFAULT 50000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
    max_user_id INTEGER;
BEGIN
    SELECT MAX(user_id) INTO max_user_id FROM test_users;
    RAISE NOTICE 'Generating % orders...', num_orders;
    
    FOR i IN 1..num_orders LOOP
        INSERT INTO test_orders (
            order_number, user_id, order_date, status, total_amount, 
            tax_amount, shipping_cost, discount_amount, final_amount,
            payment_method, payment_status, shipping_address, tracking_number, metadata
        )
        VALUES (
            'ORD-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || LPAD(i::TEXT, 8, '0'),
            floor(random() * max_user_id + 1)::INTEGER,
            CURRENT_TIMESTAMP - (random() * INTERVAL '365 days'),
            CASE 
                WHEN random() < 0.6 THEN 'completed'
                WHEN random() < 0.8 THEN 'shipped'
                ELSE 'pending'
            END,
            (random() * 2000 + 50)::DECIMAL(12,2),
            (random() * 200)::DECIMAL(12,2),
            (random() * 30 + 5)::DECIMAL(10,2),
            (random() * 50)::DECIMAL(10,2),
            (random() * 2000)::DECIMAL(12,2),
            'credit_card',
            'paid',
            random_city() || ', ul. Testowa 1',
            'TRK' || floor(random() * 1000000000)::BIGINT::TEXT,
            jsonb_build_object('priority', false)
        );
        
        IF i % 5000 = 0 THEN
            RAISE NOTICE 'Generated % orders...', i;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Orders completed';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_order_items()
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    order_rec RECORD;
    max_product_id INTEGER;
    counter INTEGER := 0;
    items_count INTEGER;
    j INTEGER;
BEGIN
    SELECT MAX(product_id) INTO max_product_id FROM test_products;
    RAISE NOTICE 'Generating order items...';
    
    FOR order_rec IN SELECT order_id FROM test_orders LOOP
        items_count := floor(random() * 5 + 1)::INTEGER;
        
        FOR j IN 1..items_count LOOP
            INSERT INTO test_order_items (order_id, product_id, quantity, unit_price, line_total)
            VALUES (
                order_rec.order_id,
                floor(random() * max_product_id + 1)::INTEGER,
                floor(random() * 5 + 1)::INTEGER,
                (random() * 500 + 10)::DECIMAL(10,2),
                (random() * 1000)::DECIMAL(12,2)
            );
        END LOOP;
        
        counter := counter + 1;
        IF counter % 5000 = 0 THEN
            RAISE NOTICE 'Generated items for % orders...', counter;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Order items completed';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_activity_logs(num_logs INTEGER DEFAULT 100000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
    max_user_id INTEGER;
    actions TEXT[] := ARRAY['login', 'logout', 'view_product', 'add_to_cart'];
BEGIN
    SELECT MAX(user_id) INTO max_user_id FROM test_users;
    RAISE NOTICE 'Generating % logs...', num_logs;
    
    FOR i IN 1..num_logs LOOP
        INSERT INTO test_activity_logs (user_id, action, log_date, details)
        VALUES (
            floor(random() * max_user_id + 1)::INTEGER,
            actions[floor(random() * 4 + 1)],
            CURRENT_TIMESTAMP - (random() * INTERVAL '90 days'),
            jsonb_build_object('test', true)
        );
        
        IF i % 10000 = 0 THEN
            RAISE NOTICE 'Generated % logs...', i;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Logs completed';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_transactions()
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    order_rec RECORD;
    counter INTEGER := 0;
BEGIN
    RAISE NOTICE 'Generating transactions...';
    
    FOR order_rec IN SELECT order_id, user_id, final_amount FROM test_orders WHERE status != 'cancelled' LOOP
        INSERT INTO test_transactions (user_id, order_id, transaction_type, amount, status, reference_number)
        VALUES (
            order_rec.user_id,
            order_rec.order_id,
            'payment',
            order_rec.final_amount,
            'completed',
            'TXN-' || floor(random() * 1000000000)::BIGINT::TEXT
        );
        
        counter := counter + 1;
        IF counter % 5000 = 0 THEN
            RAISE NOTICE 'Generated % transactions...', counter;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Transactions completed';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_inventory()
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    product_rec RECORD;
    counter INTEGER := 0;
BEGIN
    RAISE NOTICE 'Generating inventory...';
    
    FOR product_rec IN SELECT product_id FROM test_products LOOP
        INSERT INTO test_inventory (product_id, warehouse_id, quantity, reserved_quantity, location)
        VALUES (
            product_rec.product_id,
            floor(random() * 5 + 1)::INTEGER,
            floor(random() * 500)::INTEGER,
            floor(random() * 50)::INTEGER,
            'Aisle-' || floor(random() * 20 + 1)::TEXT
        );
        
        counter := counter + 1;
        IF counter % 1000 = 0 THEN
            RAISE NOTICE 'Generated inventory for % products...', counter;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Inventory completed';
END;
$function$;

CREATE OR REPLACE FUNCTION generate_test_reviews(num_reviews INTEGER DEFAULT 20000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
    max_user_id INTEGER;
    max_product_id INTEGER;
BEGIN
    SELECT MAX(user_id) INTO max_user_id FROM test_users;
    SELECT MAX(product_id) INTO max_product_id FROM test_products;
    RAISE NOTICE 'Generating % reviews...', num_reviews;
    
    FOR i IN 1..num_reviews LOOP
        INSERT INTO test_reviews (product_id, user_id, rating, review_title, review_text)
        VALUES (
            floor(random() * max_product_id + 1)::INTEGER,
            floor(random() * max_user_id + 1)::INTEGER,
            floor(random() * 5 + 1)::INTEGER,
            'Review ' || i,
            'Great product!'
        );
        
        IF i % 5000 = 0 THEN
            RAISE NOTICE 'Generated % reviews...', i;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Reviews completed';
END;
$function$;

-- ============================================================================
-- MASTER - GENEROWANIE WSZYSTKICH DANYCH
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_all_test_data(
    users INTEGER DEFAULT 10000,
    products INTEGER DEFAULT 5000,
    orders INTEGER DEFAULT 50000,
    logs INTEGER DEFAULT 100000,
    reviews INTEGER DEFAULT 20000
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE 'Starting test data generation...';
    
    PERFORM generate_test_categories();
    PERFORM generate_test_users(users);
    PERFORM generate_test_products(products);
    PERFORM generate_test_orders(orders);
    PERFORM generate_test_order_items();
    PERFORM generate_test_activity_logs(logs);
    PERFORM generate_test_transactions();
    PERFORM generate_test_inventory();
    PERFORM generate_test_reviews(reviews);
    
    RAISE NOTICE 'Test data generation COMPLETED';
END;
$function$;

-- ============================================================================
-- TWORZENIE INDEKSÓW
-- ============================================================================

CREATE OR REPLACE FUNCTION create_used_indexes()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE 'Creating USED indexes...';
    
    CREATE INDEX IF NOT EXISTS idx_users_email_used ON test_users(email);
    CREATE INDEX IF NOT EXISTS idx_users_status_used ON test_users(status);
    CREATE INDEX IF NOT EXISTS idx_orders_user_id_used ON test_orders(user_id);
    CREATE INDEX IF NOT EXISTS idx_orders_status_used ON test_orders(status);
    CREATE INDEX IF NOT EXISTS idx_products_category_used ON test_products(category);
    CREATE INDEX IF NOT EXISTS idx_order_items_order_id_used ON test_order_items(order_id);
    
    RAISE NOTICE 'USED indexes created';
END;
$function$;

CREATE OR REPLACE FUNCTION create_unused_indexes()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE 'Creating UNUSED indexes...';
    
    CREATE INDEX IF NOT EXISTS idx_users_phone_unused ON test_users(phone);
    CREATE INDEX IF NOT EXISTS idx_users_postal_code_unused ON test_users(postal_code);
    CREATE INDEX IF NOT EXISTS idx_products_weight_unused ON test_products(weight_kg);
    CREATE INDEX IF NOT EXISTS idx_products_sku_unused ON test_products(sku);
    CREATE INDEX IF NOT EXISTS idx_orders_shipped_date_unused ON test_orders(shipped_date);
    CREATE INDEX IF NOT EXISTS idx_logs_session_unused ON test_activity_logs(session_id);
    
    RAISE NOTICE 'UNUSED indexes created';
END;
$function$;

CREATE OR REPLACE FUNCTION create_duplicate_indexes()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE 'Creating DUPLICATE indexes...';
    
    CREATE INDEX IF NOT EXISTS idx_users_email_dup1 ON test_users(email);
    CREATE INDEX IF NOT EXISTS idx_users_email_dup2 ON test_users(email);
    CREATE INDEX IF NOT EXISTS idx_orders_user_short ON test_orders(user_id);
    CREATE INDEX IF NOT EXISTS idx_orders_user_status_long ON test_orders(user_id, status);
    
    RAISE NOTICE 'DUPLICATE indexes created';
END;
$function$;

CREATE OR REPLACE FUNCTION create_all_test_indexes()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE 'Creating all test indexes...';
    
    PERFORM create_used_indexes();
    PERFORM create_unused_indexes();
    PERFORM create_duplicate_indexes();
    
    RAISE NOTICE 'All indexes created';
END;
$function$;

-- ============================================================================
-- WORKLOAD SYMULACJE
-- ============================================================================

CREATE OR REPLACE FUNCTION simulate_workload_with_indexes(iterations INTEGER DEFAULT 1000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
BEGIN
    RAISE NOTICE 'Running workload WITH indexes...';
    
    FOR i IN 1..iterations LOOP
        PERFORM * FROM test_users WHERE email LIKE '%user%' LIMIT 10;
        PERFORM * FROM test_users WHERE status = 'active' LIMIT 100;
        PERFORM * FROM test_orders WHERE user_id = floor(random() * 1000 + 1)::INTEGER;
        PERFORM * FROM test_orders WHERE status = 'completed' LIMIT 50;
        PERFORM * FROM test_products WHERE category = 'Elektronika' LIMIT 20;
        PERFORM * FROM test_order_items WHERE order_id = floor(random() * 5000 + 1)::INTEGER;
        
        IF i % 200 = 0 THEN
            RAISE NOTICE 'Progress: %/%', i, iterations;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Workload WITH indexes completed';
END;
$function$;

CREATE OR REPLACE FUNCTION simulate_workload_avoiding_indexes(iterations INTEGER DEFAULT 500)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
BEGIN
    RAISE NOTICE 'Running workload AVOIDING indexes...';
    
    FOR i IN 1..iterations LOOP
        PERFORM * FROM test_users WHERE username = 'user_' || floor(random() * 1000 + 1)::INTEGER;
        PERFORM * FROM test_products WHERE price > 100 LIMIT 10;
        PERFORM * FROM test_activity_logs WHERE user_id = floor(random() * 1000 + 1)::INTEGER LIMIT 5;
        
        IF i % 100 = 0 THEN
            RAISE NOTICE 'Progress: %/%', i, iterations;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Workload AVOIDING indexes completed';
END;
$function$;

CREATE OR REPLACE FUNCTION simulate_read_load_slow(iterations INTEGER DEFAULT 500)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
BEGIN
    RAISE NOTICE 'Running SLOW queries...';
    
    FOR i IN 1..iterations LOOP
        PERFORM u.username, COUNT(o.order_id)
        FROM test_users u
        LEFT JOIN test_orders o ON u.user_id = o.user_id
        WHERE u.city = random_city()
        GROUP BY u.username
        HAVING COUNT(o.order_id) > 0;
        
        PERFORM p.product_name, SUM(oi.quantity)
        FROM test_products p
        JOIN test_order_items oi ON p.product_id = oi.product_id
        GROUP BY p.product_name
        ORDER BY SUM(oi.quantity) DESC
        LIMIT 10;
        
        IF i % 100 = 0 THEN
            RAISE NOTICE 'Progress: %/%', i, iterations;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'SLOW queries completed';
END;
$function$;

CREATE OR REPLACE FUNCTION simulate_write_load(iterations INTEGER DEFAULT 1000)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
BEGIN
    RAISE NOTICE 'Running WRITE load...';
    
    FOR i IN 1..iterations LOOP
        INSERT INTO test_activity_logs (user_id, action, details)
        VALUES (floor(random() * 1000 + 1)::INTEGER, 'test_action', '{}');
        
        UPDATE test_users 
        SET last_login = CURRENT_TIMESTAMP
        WHERE user_id = floor(random() * 1000 + 1)::INTEGER;
        
        UPDATE test_orders 
        SET status = 'completed'
        WHERE order_id = (SELECT order_id FROM test_orders ORDER BY random() LIMIT 1);
        
        DELETE FROM test_activity_logs
        WHERE log_date < CURRENT_DATE - INTERVAL '60 days'
        AND log_id IN (SELECT log_id FROM test_activity_logs 
                       WHERE log_date < CURRENT_DATE - INTERVAL '60 days' 
                       LIMIT 5);
        
        IF i % 200 = 0 THEN
            RAISE NOTICE 'Progress: %/%', i, iterations;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'WRITE load completed';
END;
$function$;

CREATE OR REPLACE FUNCTION simulate_high_memory_queries(iterations INTEGER DEFAULT 20)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    i INTEGER;
BEGIN
    RAISE NOTICE 'Running HIGH MEMORY queries...';
    SET work_mem = '1MB';
    
    FOR i IN 1..iterations LOOP
        PERFORM 
            o.user_id,
            COUNT(*) as order_count,
            SUM(o.final_amount) as total_spent
        FROM test_orders o
        JOIN test_users u ON o.user_id = u.user_id
        GROUP BY o.user_id
        ORDER BY total_spent DESC;
        
        IF i % 5 = 0 THEN
            RAISE NOTICE 'Progress: %/%', i, iterations;
        END IF;
    END LOOP;
    
    RESET work_mem;
    RAISE NOTICE 'HIGH MEMORY queries completed';
END;
$function$;

-- ============================================================================
-- MASTER FUNCTION - KOMPLETNA INICJALIZACJA
-- ============================================================================

CREATE OR REPLACE FUNCTION initialize_complete_test_environment(
    p_num_users INTEGER DEFAULT 10000,
    p_num_products INTEGER DEFAULT 5000,
    p_num_orders INTEGER DEFAULT 50000,
    p_num_logs INTEGER DEFAULT 100000,
    p_num_reviews INTEGER DEFAULT 20000,
    p_read_iterations INTEGER DEFAULT 500,
    p_write_iterations INTEGER DEFAULT 1000,
    p_index_workload_iterations INTEGER DEFAULT 1000
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE '========== COMPLETE INITIALIZATION START ==========';
    
    RAISE NOTICE '[1/11] Generating categories...';
    PERFORM generate_test_categories();
    
    RAISE NOTICE '[2/11] Generating % users...', p_num_users;
    PERFORM generate_test_users(p_num_users);
    
    RAISE NOTICE '[3/11] Generating % products...', p_num_products;
    PERFORM generate_test_products(p_num_products);
    
    RAISE NOTICE '[4/11] Generating % orders...', p_num_orders;
    PERFORM generate_test_orders(p_num_orders);
    
    RAISE NOTICE '[5/11] Generating order items...';
    PERFORM generate_test_order_items();
    
    RAISE NOTICE '[6/11] Generating % logs...', p_num_logs;
    PERFORM generate_test_activity_logs(p_num_logs);
    
    RAISE NOTICE '[7/11] Generating transactions...';
    PERFORM generate_test_transactions();
    
    RAISE NOTICE '[8/11] Generating inventory...';
    PERFORM generate_test_inventory();
    
    RAISE NOTICE '[9/11] Generating % reviews...', p_num_reviews;
    PERFORM generate_test_reviews(p_num_reviews);
    
    RAISE NOTICE '[10/11] Creating indexes...';
    PERFORM create_all_test_indexes();
    
    RAISE NOTICE '[11/11] Running workloads...';
    PERFORM simulate_workload_with_indexes(p_index_workload_iterations);
    PERFORM simulate_workload_avoiding_indexes(p_index_workload_iterations / 2);
    PERFORM simulate_read_load_slow(p_read_iterations);
    PERFORM simulate_write_load(p_write_iterations);
    PERFORM simulate_high_memory_queries(20);
    
    RAISE NOTICE '';
    RAISE NOTICE '========== INITIALIZATION COMPLETED ==========';
    RAISE NOTICE 'Statistics:';
    RAISE NOTICE '  Users: %', (SELECT COUNT(*) FROM test_users);
    RAISE NOTICE '  Products: %', (SELECT COUNT(*) FROM test_products);
    RAISE NOTICE '  Orders: %', (SELECT COUNT(*) FROM test_orders);
    RAISE NOTICE '  Indexes: %', (SELECT COUNT(*) FROM pg_indexes WHERE tablename LIKE 'test_%');
    RAISE NOTICE '';
    RAISE NOTICE 'NEXT: Run diagnostic queries from first artifact!';
END;
$function$;

-- ============================================================================
-- PRESETY
-- ============================================================================

CREATE OR REPLACE FUNCTION quick_test()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM initialize_complete_test_environment(1000, 500, 5000, 10000, 2000, 100, 100, 200);
END;
$function$;

CREATE OR REPLACE FUNCTION medium_test()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM initialize_complete_test_environment(10000, 5000, 50000, 100000, 20000, 500, 500, 1000);
END;
$function$;

CREATE OR REPLACE FUNCTION large_test()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM initialize_complete_test_environment(50000, 20000, 200000, 500000, 100000, 2000, 2000, 3000);
END;
$function$;

-- ============================================================================
-- CLEANUP
-- ============================================================================

CREATE OR REPLACE FUNCTION cleanup_test_data()
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    TRUNCATE TABLE test_reviews CASCADE;
    TRUNCATE TABLE test_inventory CASCADE;
    TRUNCATE TABLE test_transactions CASCADE;
    TRUNCATE TABLE test_activity_logs CASCADE;
    TRUNCATE TABLE test_order_items CASCADE;
    TRUNCATE TABLE test_orders CASCADE;
    TRUNCATE TABLE test_products CASCADE;
    TRUNCATE TABLE test_categories CASCADE;
    TRUNCATE TABLE test_users CASCADE;
    RAISE NOTICE 'All test data cleaned';
END;
$function$;

-- ============================================================================
-- QUICK START - WYBIERZ PRESET
-- ============================================================================

-- SZYBKI TEST (1-2 minuty):
-- SELECT quick_test();

-- ŚREDNI TEST (5-10 minut) - POLECANY:
-- SELECT medium_test();

-- DUŻY TEST (30+ minut):
-- SELECT large_test();

-- Lub custom:
-- SELECT initialize_complete_test_environment(10000, 5000, 50000, 100000, 20000, 500, 1000, 1000);
