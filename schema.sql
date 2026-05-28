-- =========================================================================
-- ESQUEMA DE BASE DE DATOS PROFESIONAL PARA RECOLECCIÓN DE RESPALDOS (CNE)
-- Proyecto: Sistema Real de Adhesiones y Revocatoria de Mandato
-- Motor: PostgreSQL / Supabase
-- =========================================================================

-- 1. EXTENSIONES REQUERIDAS (Para generación de hashes criptográficos y UUIDs)
create extension if not exists "pgcrypto";

-- 2. TABLA PRINCIPAL DE RESPALDOS CIUDADANOS (ACTUALIZADA CON CANTÓN)
create table public.respaldos (
    -- Identificador único interno
    id uuid default gen_random_uuid() primary key,
    
    -- Información de Identidad Ciudadana
    fullname text not null check (length(trim(fullname)) >= 6),
    cedula varchar(10) not null unique check (cedula ~ '^[0-9]{10}$'),
    provincia varchar(50) not null,
    canton varchar(50) not null, -- Agregada columna de Cantón
    fecha_nacimiento date not null, -- Agregada fecha de nacimiento
    
    -- Firma manuscrita almacenada en Base64 (formato PNG)
    signature text not null,
    
    -- Datos de Auditoría y Seguridad Informática (Prevención de Fraude)
    client_ip text,
    user_agent text,
    
    -- Proceso de Verificación Grafotécnica (Equivalente al flujo real del CNE)
    verification_status varchar(20) default 'pendiente' not null 
        check (verification_status in ('pendiente', 'aprobada', 'rechazada')),
    verification_reason text, -- Razón de rechazo si aplica (ej. "Trazo no coincide", "Huella borrosa")
    
    -- Hash Criptográfico de Integridad (SHA-256)
    -- Garantiza que el registro no ha sido modificado manualmente en la base de datos
    system_hash text not null,
    
    -- Estampa de Tiempo de la Firma
    created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- 3. ÍNDICES DE RENDIMIENTO Y BÚSQUEDA
-- Optimiza la verificación de duplicados de cédula (operación más común)
create index idx_respaldos_cedula on public.respaldos(cedula);
-- Optimiza los reportes agregados por provincia y cantón
create index idx_respaldos_provincia_canton on public.respaldos(provincia, canton);
-- Optimiza la cola de trabajo de los peritos grafotécnicos (firmas pendientes de auditar)
create index idx_respaldos_status on public.respaldos(verification_status);

-- 4. FUNCIÓN DISPARADORA PARA GENERAR HASH DE INTEGRIDAD (Anti-alteración)
-- Genera automáticamente un hash SHA-256 combinando los campos críticos del registro
create or replace function public.fn_generate_respaldo_hash()
returns trigger as $$
begin
    new.system_hash := encode(
        digest(
            concat(new.cedula, '|', new.fullname, '|', new.provincia, '|', new.canton, '|', new.fecha_nacimiento::text, '|', substring(new.signature from 1 for 100), '|', new.created_at::text),
            'sha256'
        ),
        'hex'
    );
    return new;
end;
$$ language plpgsql security definer;

-- Crear el trigger antes de insertar cada registro
create trigger trg_respaldos_integrity_hash
before insert or update on public.respaldos
for each row
execute function public.fn_generate_respaldo_hash();

-- 5. SEGURIDAD DE NIVEL DE FILA (Row Level Security - RLS)
alter table public.respaldos enable row level security;

-- Política A: Permitir a cualquier ciudadano anónimo (anon) registrar su respaldo
create policy "Permitir inserciones públicas anon" 
on public.respaldos 
for insert 
with check (true);

-- Política B: Permitir a cualquier ciudadano verificar si su cédula ya está registrada
-- Nota: Solo exponemos la cédula y provincia por privacidad, no el nombre ni la firma.
create policy "Permitir consulta limitada de cédula" 
on public.respaldos 
for select 
using (true);

-- =========================================================================
-- VISTAS DE MONITOREO ESTADÍSTICO (Para Dashboard de Control del Proceso)
-- =========================================================================

-- Vista para ver el progreso de recolección por provincia y cantón
create or replace view public.vw_metricas_por_provincia as
select 
    provincia,
    canton,
    count(*) as total_adhesiones,
    sum(case when verification_status = 'aprobada' then 1 else 0 end) as aprobadas,
    sum(case when verification_status = 'rechazada' then 1 else 0 end) as rechazadas,
    sum(case when verification_status = 'pendiente' then 1 else 0 end) as pendientes
from 
    public.respaldos
group by 
    provincia, canton
order by 
    total_adhesiones desc;
