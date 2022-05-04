MODULE timecycle

   USE global
   USE mpi_common
   USE screen
   USE tools
   USE collisions
   USE postprocess
   USE fields

   CONTAINS

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE TIME_LOOP                                     !!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE TIME_LOOP

      IMPLICIT NONE
   
      INTEGER :: NP_TOT, NCOLL_TOT
      REAL(KIND=8) :: CURRENT_TIME, CURRENT_CPU_TIME, EST_TIME

      CHARACTER(len=512) :: stringTMP

      ! Init variables
      NP_TOT = 0
      CALL INIT_POSTPROCESS

      ! ########### Compute poisson ##########################################

      IF (BOOL_PIC) THEN
         CALL DEPOSIT_CHARGE
         IF (BOOL_FLUID_ELECTRONS) THEN
            CALL SOLVE_POISSON_NONLINEAR
         ELSE
            CALL SOLVE_POISSON
         END IF
         IF (BOOL_PIC_IMPLICIT) THEN
            CALL DEPOSIT_CURRENT
            CALL ASSEMBLE_AMPERE
            CALL SOLVE_AMPERE
         END IF
      END IF
      
      ! Dump particles and flowfield before the first time step, but after the initial seeding
      IF (DUMP_START .EQ. 0) THEN
         CALL DUMP_PARTICLES_FILE(0)
      END IF

      IF (DUMP_GRID_START .EQ. 0 .AND. DUMP_GRID_N_AVG .EQ. 1) THEN
         CALL GRID_AVG
         CALL GRID_SAVE
         CALL GRID_RESET
      END IF


      tID = 1
      CALL CPU_TIME(START_CPU_TIME)
      DO WHILE (tID .LE. NT)

         ! ########### Print simulation info #######################################

         CURRENT_TIME = tID*DT
         CALL CPU_TIME(CURRENT_CPU_TIME)
         CURRENT_CPU_TIME = CURRENT_CPU_TIME - START_CPU_TIME 
         EST_TIME = DBLE(NT-tID)/tID*CURRENT_CPU_TIME/3600.d0

         IF (MOD(tID, STATS_EVERY) .EQ. 0) THEN
            CALL MPI_REDUCE(NP_PROC, NP_TOT, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
            CALL MPI_REDUCE(TIMESTEP_COLL, NCOLL_TOT, 1, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
            

            WRITE(stringTMP, '(A13,I8,A4,I8,A9,ES14.3,A17,F10.1,A27,F10.1,A28,I10,A25,I10)') '   Timestep: ', tID, ' of ', NT, &
                           ' - time: ', CURRENT_TIME, ' [s] - CPU time: ', CURRENT_CPU_TIME, &
                           ' [s] - est. time required: ', EST_TIME, &
                           ' [h] - number of particles: ', NP_TOT, &
                           ' - number of collisions: ', NCOLL_TOT

            CALL ONLYMASTERPRINT1(PROC_ID, TRIM(stringTMP))

         END IF
         
         ! ########### Inject particles from boundaries/injection sources ##########

         CALL BOUNDARIES_INJECT
         CALL LINE_SOURCE_INJECT
         CALL BOUNDARIES_EMIT

         !CALL FIXED_IONIZATION

         ! ########### Advect particles ############################################

         CALL ADVECT 

         ! ########### Exchange particles among processes ##########################

         CALL EXCHANGE

         ! ########### Perform collisions ##########################################

         IF (BOOL_MCC)  CALL MCC_COLLISIONS

         IF (BOOL_DSMC .AND. GRID_TYPE .NE. UNSTRUCTURED) CALL DSMC_COLLISIONS
         IF (BOOL_DSMC .AND. GRID_TYPE == UNSTRUCTURED) CALL DSMC_COLLISIONS_UNSTRUCTURED

         IF (BOOL_BGK) CALL BGK_COLLISIONS

         IF (BOOL_THERMAL_BATH) CALL THERMAL_BATH

         ! ########### Dump particles ##############################################
         IF (tID .GE. DUMP_START) THEN
            IF (MOD(tID-DUMP_START, DUMP_EVERY) .EQ. 0) CALL DUMP_PARTICLES_FILE(tID)
         END IF

         ! ########### Dump flowfield ##############################################
         IF (tID .GT. DUMP_GRID_START) THEN
            ! If we are in the grid save timestep, average, then dump the cumulated averages
            IF (tID .NE. DUMP_GRID_START .AND. MOD(tID-DUMP_GRID_START, DUMP_GRID_AVG_EVERY*DUMP_GRID_N_AVG) .EQ. 0) THEN
               CALL GRID_AVG
               CALL GRID_SAVE
               CALL GRID_RESET
            ! If we are just in a grid average timestep, compute the grid average
            ELSE IF (MOD(tID-DUMP_GRID_START, DUMP_GRID_AVG_EVERY) .EQ. 0) THEN
               CALL GRID_AVG
            END IF
         END IF

         ! ########### Dump particle fluxes #######################################
         IF (BOOL_DUMP_FLUXES) CALL DUMP_FLUXES_FILE(tID)

         ! ########### Dump individual particle ###################################
         CALL DUMP_TRAJECTORY_FILE(tID)

         ! ~~~~~ Hmm that's it! ~~~~~

         ! Perform the conservation checks
         IF (PERFORM_CHECKS .AND. MOD(tID, CHECKS_EVERY) .EQ. 0) CALL CHECKS

         tID = tID + 1

         ! ########### Compute poisson ##########################################

         IF (BOOL_PIC) THEN
            IF (BOOL_PIC_IMPLICIT) THEN
               CALL DEPOSIT_CURRENT
               CALL ASSEMBLE_AMPERE
               CALL SOLVE_AMPERE
            ELSE
               CALL DEPOSIT_CHARGE
               IF (BOOL_FLUID_ELECTRONS) THEN
                  CALL SOLVE_POISSON_NONLINEAR
               ELSE
                  CALL SOLVE_POISSON
               END IF
            END IF
         END IF
         
      END DO

   END SUBROUTINE TIME_LOOP
 


   SUBROUTINE BOUNDARIES_EMIT
  
      IMPLICIT NONE
   
      INTEGER      :: IP, IC, IS, NFS, ITASK
      REAL(KIND=8) :: DTFRAC, Vdummy, V_NORM, V_PARA, X1, X2, Y1, Y2, R, NORMX, NORMY
      REAL(KIND=8) :: X, Y, Z, VX, VY, VZ, EROT, EVIB 
      TYPE(PARTICLE_DATA_STRUCTURE) :: particleNOW
   
      INTEGER :: S_ID
      REAL(KIND=8) :: M

      TYPE(EMIT_TASK_DATA_STRUCTURE) :: EMIT_TASK

      DO ITASK = 1, N_EMIT_TASKS
         EMIT_TASK = EMIT_TASKS(ITASK)

         X1 = U2D_GRID%NODE_COORDS(EMIT_TASK%IV1, 1)
         Y1 = U2D_GRID%NODE_COORDS(EMIT_TASK%IV1, 2)
         X2 = U2D_GRID%NODE_COORDS(EMIT_TASK%IV2, 1)
         Y2 = U2D_GRID%NODE_COORDS(EMIT_TASK%IV2, 2)

         IC = EMIT_TASK%IC

         DO IS = 1, MIXTURES(EMIT_TASK%MIX_ID)%N_COMPONENTS ! Loop on mixture components

            S_ID = MIXTURES(EMIT_TASK%MIX_ID)%COMPONENTS(IS)%ID
            M = SPECIES(S_ID)%MOLECULAR_MASS
            NFS = FLOOR(EMIT_TASK%NFS(IS))
            IF (EMIT_TASK%NFS(IS)-REAL(NFS, KIND=8) .GE. rf()) THEN ! Same as SPARTA's perspeciess
               NFS = NFS + 1
            END IF


            DO IP = 1, NFS ! Loop on particles to be injected

               CALL MAXWELL(0.d0, 0.d0, 0.d0, &
                           EMIT_TASK%TTRA, EMIT_TASK%TTRA, EMIT_TASK%TTRA, &
                           Vdummy, V_PARA, VZ, M)

               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, EMIT_TASK%TROT, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, EMIT_TASK%TVIB, EVIB)

               V_NORM = FLX(EMIT_TASK%S_NORM, EMIT_TASK%TTRA, M)

               NORMX = -U2D_GRID%EDGE_NORMAL(EMIT_TASK%IC,EMIT_TASK%IEDGE,1)
               NORMY = -U2D_GRID%EDGE_NORMAL(EMIT_TASK%IC,EMIT_TASK%IEDGE,2)

               VX = V_NORM*NORMX - V_PARA*NORMY + EMIT_TASK%UX
               VY = V_PARA*NORMX + V_NORM*NORMY + EMIT_TASK%UY
               VZ = VZ + EMIT_TASK%UZ

               DTFRAC = rf()*DT

               R = rf()
               IF (AXI) THEN
                  IF (Y1 == Y2) THEN
                     Y = Y1
                     X = X1 + R*(X2-X1)
                     Z = 0
                  ELSE IF (Y1 < Y2) THEN
                     Y = SQRT(Y1*Y1 + R*(Y2*Y2 - Y1*Y1))
                     X = X1 + (Y-Y1)/(Y2-Y1)*(X2-X1)
                     Z = 0
                  ELSE
                     Y = SQRT(Y2*Y2 + R*(Y1*Y1 - Y2*Y2))
                     X = X2 + (Y-Y2)/(Y1-Y2)*(X1-X2)
                     Z = 0
                  END IF
               ELSE
                  X = X1 + R*(X2-X1)
                  Y = Y1 + R*(Y2-Y1)
                  Z = ZMIN + (ZMAX-ZMIN)*rf()
               END IF

               ! Init a particle object and assign it to the local vector of particles
               CALL INIT_PARTICLE(X,Y,Z,VX,VY,VZ,EROT,EVIB,S_ID,IC,DTFRAC,  particleNOW)
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles)

            END DO

         END DO
      END DO

   END SUBROUTINE BOUNDARIES_EMIT



   SUBROUTINE FIXED_IONIZATION
  

      IMPLICIT NONE

      INTEGER            :: IP, NP_INIT, IC
      REAL(KIND=8)       :: Xp, Yp, Zp, VXp, VYp, VZp, EROT, EVIB, DOMAIN_VOLUME, DTFRAC
      INTEGER            :: CID

      REAL(KIND=8), DIMENSION(3) :: V1, V2, V3
      REAL(KIND=8)       :: XI, ETA, ETATEMP

      TYPE(PARTICLE_DATA_STRUCTURE) :: particleNOW
      REAL(KIND=8)  :: M
      INTEGER       :: S_ID, i

      REAL(KIND=8)  :: NDOT = 1.d12

      ! Print message 
      CALL ONLYMASTERPRINT1(PROC_ID, '> SEEDING IONIZED PARTICLES IN THE DOMAIN...')
     
      ! Compute number of particles to be seeded
      !NP_INIT = NINT(NRHO_INIT/FNUM*(XMAX-XMIN)*(YMAX-YMIN)*(ZMAX-ZMIN))

      !CALL ONLYMASTERPRINT2(PROC_ID, '   Particles to be seeded', REAL(NP_INIT, KIND=8))
 
      ! Compute number of particles to be seeded by every process
      !NPPP_INIT = INT(NP_INIT/N_MPI_THREADS) 

      ! Create particles in the domain
      DO i = 1, MIXTURES(MIX_INIT)%N_COMPONENTS
         
         S_ID = MIXTURES(MIX_INIT)%COMPONENTS(i)%ID
         IF (GRID_TYPE == UNSTRUCTURED) THEN
            DO IC = 1, U2D_GRID%NUM_CELLS
               ! Compute number of particles of this species per process to be created in this cell.
               NP_INIT = RANDINT(NDOT/FNUM*CELL_VOLUMES(IC)*DT* &
                           MIXTURES(MIX_INIT)%COMPONENTS(i)%MOLFRAC/N_MPI_THREADS)
               IF (NP_INIT == 0) CYCLE

               V1 = U2D_GRID%NODE_COORDS(U2D_GRID%CELL_NODES(IC,1),:)
               V2 = U2D_GRID%NODE_COORDS(U2D_GRID%CELL_NODES(IC,2),:)
               V3 = U2D_GRID%NODE_COORDS(U2D_GRID%CELL_NODES(IC,3),:)

               DO IP = 1, NP_INIT

                  ! Create particle position randomly in the cell
                  XI = rf()
                  ETATEMP = rf()
                  IF (ETATEMP > 1-XI) THEN
                     ETA = 1-XI
                     XI = 1-ETATEMP
                  ELSE
                     ETA = ETATEMP
                  END IF

                  XP = V1(1) + (V2(1)-V1(1))*XI + (V3(1)-V1(1))*ETA
                  YP = V1(2) + (V2(2)-V1(2))*XI + (V3(2)-V1(2))*ETA
                  ZP = ZMIN + (ZMAX-ZMIN)*rf()

                  ! Assign velocity and energy following a Boltzmann distribution
                  M = SPECIES(S_ID)%MOLECULAR_MASS
                  CALL MAXWELL(UX_INIT, UY_INIT, UZ_INIT, &
                               TTRAX_INIT, TTRAY_INIT, TTRAZ_INIT, &
                               VXP, VYP, VZP, M)

                  CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, TROT_INIT, EROT)
                  CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, TVIB_INIT, EVIB)

                  DTFRAC = rf()*DT

                  CALL INIT_PARTICLE(XP,YP,ZP,VXP,VYP,VZP,EROT,EVIB,S_ID,IC,DTFRAC, particleNOW) ! Save in particle
                  CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles) ! Add particle to local array
               END DO
            END DO
         ELSE ! Structured grid
            ! Compute number of particles of this species per process to be created.
            IF (AXI) THEN
               DOMAIN_VOLUME = 0.5*(XMAX-XMIN)*(YMAX**2-YMIN**2)*(ZMAX-ZMIN)
            ELSE
               DOMAIN_VOLUME = (XMAX-XMIN)*(YMAX-YMIN)*(ZMAX-ZMIN)
            END IF
            NP_INIT = NINT(NDOT/FNUM*DOMAIN_VOLUME*DT* &
                        MIXTURES(MIX_INIT)%COMPONENTS(i)%MOLFRAC/N_MPI_THREADS)
            IF (NP_INIT == 0) CYCLE
            DO IP = 1, NP_INIT

               ! Create particle position randomly in the domain
               XP = XMIN + (XMAX-XMIN)*rf()
               !XP = XMIN + 0.5*(XMAX-XMIN)*rf()
               !IF (XP .GT. 0.) CYCLE
               IF (AXI .AND. (.NOT. BOOL_RADIAL_WEIGHTING)) THEN
                  YP = SQRT(YMIN*YMIN + rf()*(YMAX*YMAX - YMIN*YMIN))
                  ZP = 0
               ELSE
                  YP = YMIN + (YMAX-YMIN)*rf()
                  ZP = ZMIN + (ZMAX-ZMIN)*rf()
               END IF
            
               ! Assign velocity and energy following a Boltzmann distribution
               M = SPECIES(S_ID)%MOLECULAR_MASS
               IF (S_ID == 15) THEN
                  CALL MAXWELL(UX_INIT, UY_INIT, UZ_INIT, &
                           3.d-2, 3.d-2, 3.d-2, &
                           VXP, VYP, VZP, M)
               ELSE
                  CALL MAXWELL(UX_INIT, UY_INIT, UZ_INIT, &
                              TTRAX_INIT, TTRAY_INIT, TTRAZ_INIT, &
                              VXP, VYP, VZP, M)
               END IF

               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, TROT_INIT, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, TVIB_INIT, EVIB)

               CALL CELL_FROM_POSITION(XP,YP,  CID) ! Find cell containing particle

               DTFRAC = rf()*DT

               CALL INIT_PARTICLE(XP,YP,ZP,VXP,VYP,VZP,EROT,EVIB,S_ID,CID,DTFRAC, particleNOW) ! Save in particle
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles) ! Add particle to local array
            END DO
         END IF
      END DO
      ! ~~~~~~ At this point, exchange particles among processes ~~~~~~
      CALL EXCHANGE

   END SUBROUTINE FIXED_IONIZATION



   ! Should not be used in unstructured.
   SUBROUTINE LINE_SOURCE_INJECT
  
      IMPLICIT NONE
   
      INTEGER      :: IP, IC, IS, NFS, ILINE, DUMP_COUNTER
      REAL(KIND=8) :: DTFRAC, Vdummy, V_NORM, V_PERP, X1, X2, Y1, Y2, R
      REAL(KIND=8) :: X, Y, Z, VX, VY, VZ, EROT, EVIB 
      TYPE(PARTICLE_DATA_STRUCTURE) :: particleNOW
   
      INTEGER :: S_ID
      REAL(KIND=8) :: M

      INTEGER, DIMENSION(:), ALLOCATABLE :: LOCAL_LINE_EMIT_COUNT

      ALLOCATE(LOCAL_LINE_EMIT_COUNT(N_LINESOURCES*N_SPECIES))
      LOCAL_LINE_EMIT_COUNT = 0

   
      ! Linesource
      DO ILINE = 1, N_LINESOURCES
         
         DO IS = 1, MIXTURES(LINESOURCES(ILINE)%MIX_ID)%N_COMPONENTS ! Loop on mixture components

            S_ID = MIXTURES(LINESOURCES(ILINE)%MIX_ID)%COMPONENTS(IS)%ID
            M = SPECIES(S_ID)%MOLECULAR_MASS
            NFS = FLOOR(LINESOURCES(ILINE)%nfs(IS))
            IF (LINESOURCES(ILINE)%nfs(IS)-REAL(NFS, KIND=8) .GE. rf()) THEN ! Same as SPARTA's perspeciess
               NFS = NFS + 1
            END IF
            DUMP_COUNTER = 0
            DO IP = 1, NFS ! Loop on particles to be injected
               
               CALL MAXWELL(0.d0, 0.d0, 0.d0, &
                            LINESOURCES(ILINE)%TTRA, LINESOURCES(ILINE)%TTRA, LINESOURCES(ILINE)%TTRA, &
                            Vdummy, V_PERP, VZ, M)

               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, LINESOURCES(ILINE)%TROT, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, LINESOURCES(ILINE)%TVIB, EVIB)
                            
               V_NORM = FLX(LINESOURCES(ILINE)%S_NORM, LINESOURCES(ILINE)%TTRA, M) !!AAAAAAAAAAA

               VX = V_NORM*LINESOURCES(ILINE)%NORMX - V_PERP*LINESOURCES(ILINE)%NORMY + LINESOURCES(ILINE)%UX
               VY = V_PERP*LINESOURCES(ILINE)%NORMX + V_NORM*LINESOURCES(ILINE)%NORMY + LINESOURCES(ILINE)%UY
               VZ = VZ + LINESOURCES(ILINE)%UZ

               DTFRAC = rf()*DT

               R = rf()
               IF (DIMS == 2 .AND. AXI .AND. (.NOT. BOOL_RADIAL_WEIGHTING)) THEN
                  ! Correct but not really robust when Y1 \approx Y2
                  IF (LINESOURCES(ILINE)%Y1 == LINESOURCES(ILINE)%Y2) THEN
                     Y = LINESOURCES(ILINE)%Y1
                     X = LINESOURCES(ILINE)%X1 + R*(LINESOURCES(ILINE)%X2-LINESOURCES(ILINE)%X1)
                     Z = 0
                  ELSE
                     IF (LINESOURCES(ILINE)%Y1 < LINESOURCES(ILINE)%Y2) THEN
                        Y1 = LINESOURCES(ILINE)%Y1
                        Y2 = LINESOURCES(ILINE)%Y2
                        X1 = LINESOURCES(ILINE)%X1
                        X2 = LINESOURCES(ILINE)%X2
                     ELSE
                        Y1 = LINESOURCES(ILINE)%Y2
                        Y2 = LINESOURCES(ILINE)%Y1
                        X1 = LINESOURCES(ILINE)%X2
                        X2 = LINESOURCES(ILINE)%X1
                     END IF
                     Y = SQRT(Y1*Y1 + R*(Y2*Y2 - Y1*Y1))
                     X = X1 + (Y-Y1)/(Y2-Y1)*(X2-X1)
                     Z = 0
                  END IF
               ELSE
                  X = LINESOURCES(ILINE)%X1 + R*(LINESOURCES(ILINE)%X2-LINESOURCES(ILINE)%X1)
                  Y = LINESOURCES(ILINE)%Y1 + R*(LINESOURCES(ILINE)%Y2-LINESOURCES(ILINE)%Y1)
                  Z = ZMIN + (ZMAX-ZMIN)*rf()
               END IF
   
               CALL CELL_FROM_POSITION(X,Y,  IC)
   
               ! Init a particle object and assign it to the local vector of particles
               CALL INIT_PARTICLE(X,Y,Z,VX,VY,VZ,EROT,EVIB,S_ID,IC,DTFRAC,  particleNOW)
               IF ((tID == TRAJECTORY_DUMP_START) .AND. (DUMP_COUNTER < TRAJECTORY_DUMP_NUMBER)) THEN
                  particleNOW%DUMP_TRAJ = .TRUE.
                  DUMP_COUNTER = DUMP_COUNTER + 1
               END IF
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles)
   
            END DO

            LOCAL_LINE_EMIT_COUNT(ILINE+N_LINESOURCES*(S_ID-1)) = LOCAL_LINE_EMIT_COUNT(ILINE+N_LINESOURCES*(S_ID-1)) + NFS

         END DO
   
      END DO


      ! Compute total of particles injected
      CALL MPI_REDUCE(LOCAL_LINE_EMIT_COUNT, LINE_EMIT_COUNT, N_LINESOURCES*N_SPECIES, MPI_INTEGER, MPI_SUM, &
      0, MPI_COMM_WORLD, ierr)

      DEALLOCATE(LOCAL_LINE_EMIT_COUNT)
         
   END SUBROUTINE LINE_SOURCE_INJECT


   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE BOUNDARIES_INJECT -> Injects particles from domain borders !!!!!!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! Deprecated.
   SUBROUTINE BOUNDARIES_INJECT
   
      IMPLICIT NONE

      INTEGER      :: IP, IC, IS, NFS
      REAL(KIND=8) :: DTFRAC, Vdummy 
      REAL(KIND=8) :: X, Y, Z, VX, VY, VZ, EROT, EVIB 
      TYPE(PARTICLE_DATA_STRUCTURE) :: particleNOW

      INTEGER :: S_ID
      REAL(KIND=8) :: M


      ! Low X boundary (left)
      IF (BOOL_INJ_XMIN) THEN

         DO IS = 1, MIXTURES(MIX_BOUNDINJECT)%N_COMPONENTS ! Loop on mixture components
            S_ID = MIXTURES(MIX_BOUNDINJECT)%COMPONENTS(IS)%ID
            M = SPECIES(S_ID)%MOLECULAR_MASS
            NFS = FLOOR(nfs_XMIN(IS))
            IF (nfs_XMIN(IS)-REAL(NFS, KIND=8) .GE. rf()) THEN ! Same as SPARTA's perspeciess
               NFS = NFS + 1
            END IF

            DO IP = 1, NFS ! Loop on particles to be injected

               CALL MAXWELL(UX_BOUND,UY_BOUND,UZ_BOUND, &
                           TTRA_BOUND,TTRA_BOUND,TTRA_BOUND, &
                           Vdummy,VY,VZ,M)
               
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, TROT_BOUND, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, TVIB_BOUND, EVIB)

               VX = UX_BOUND + FLX(S_NORM_XMIN,TTRA_BOUND,M) !!AAAAAAAAAAA

               DTFRAC = rf()*DT
               X = XMIN
               Y = YMIN + (YMAX-YMIN)*rf()
               Z = ZMIN + (ZMAX-ZMIN)*rf()

               CALL CELL_FROM_POSITION(X,Y,  IC)

               ! Init a particle object and assign it to the local vector of particles
               CALL INIT_PARTICLE(X,Y,Z,VX,VY,VZ,EROT,EVIB,S_ID,IC,DTFRAC,  particleNOW)
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles)

            END DO
         END DO

      END IF
         
      ! High X boundary (right)
      IF (BOOL_INJ_XMAX) THEN


         DO IS = 1, MIXTURES(MIX_BOUNDINJECT)%N_COMPONENTS ! Loop on mixture components
            S_ID = MIXTURES(MIX_BOUNDINJECT)%COMPONENTS(IS)%ID
            M = SPECIES(S_ID)%MOLECULAR_MASS
            NFS = FLOOR(nfs_XMAX(IS))
            IF (nfs_XMAX(IS)-REAL(NFS, KIND=8) .GE. rf()) THEN
               NFS = NFS + 1
            END IF

            DO IP = 1, NFS ! Loop on particles to be injected

               CALL MAXWELL(UX_BOUND,UY_BOUND,UZ_BOUND, &
                           TTRA_BOUND,TTRA_BOUND,TTRA_BOUND, &
                           Vdummy,VY,VZ,M)

               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, TROT_BOUND, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, TVIB_BOUND, EVIB)

               VX = UX_BOUND - FLX(S_NORM_XMAX,TTRA_BOUND,M) !! I think something was wrong here with the sign

               DTFRAC = rf()*DT
               X = XMAX
               Y = YMIN + (YMAX-YMIN)*rf()
               Z = ZMIN + (ZMAX-ZMIN)*rf()
               
               CALL CELL_FROM_POSITION(X,Y,  IC)

               ! Init a particle object and assign it to vector of particles
               CALL INIT_PARTICLE(X,Y,Z,VX,VY,VZ,EROT,EVIB,S_ID,IC,DTFRAC,  particleNOW)
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles)
               
            END DO
         END DO

      END IF

      ! Low Y boundary (bottom)
      IF (BOOL_INJ_YMIN) THEN

         DO IS = 1, MIXTURES(MIX_BOUNDINJECT)%N_COMPONENTS ! Loop on mixture components
            S_ID = MIXTURES(MIX_BOUNDINJECT)%COMPONENTS(IS)%ID
            M = SPECIES(S_ID)%MOLECULAR_MASS
            NFS = FLOOR(nfs_YMIN(IS))
            IF (nfs_YMIN(IS)-REAL(NFS, KIND=8) .GE. rf()) THEN
               NFS = NFS + 1
            END IF

            DO IP = 1, NFS ! Loop on particles to be injected

               CALL MAXWELL(UX_BOUND,UY_BOUND,UZ_BOUND, &
                           TTRA_BOUND,TTRA_BOUND,TTRA_BOUND, &
                           VX,Vdummy,VZ,M)

               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, TROT_BOUND, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, TVIB_BOUND, EVIB)

               VY = UY_BOUND + FLX(S_NORM_YMIN,TTRA_BOUND,M) !!AAAAAAAAAAA

               DTFRAC = rf()*DT
               X = XMIN + (XMAX-XMIN)*rf()
               Y = YMIN
               Z = ZMIN + (ZMAX-ZMIN)*rf()

               CALL CELL_FROM_POSITION(X,Y,  IC)

               ! Init a particle object and assign it to the local vector of particles
               CALL INIT_PARTICLE(X,Y,Z,VX,VY,VZ,EROT,EVIB,S_ID,IC,DTFRAC,  particleNOW)
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles)
            END DO
         END DO

      END IF
         
      ! High Y boundary (top)
      IF (BOOL_INJ_YMAX) THEN

         DO IS = 1, MIXTURES(MIX_BOUNDINJECT)%N_COMPONENTS ! Loop on mixture components
            S_ID = MIXTURES(MIX_BOUNDINJECT)%COMPONENTS(IS)%ID
            M = SPECIES(S_ID)%MOLECULAR_MASS
            NFS = FLOOR(nfs_YMAX(IS))
            IF (nfs_YMAX(IS)-REAL(NFS, KIND=8) .GE. rf()) THEN
               NFS = NFS + 1
            END IF

            DO IP = 1, NFS ! Loop on particles to be injected

               CALL MAXWELL(UX_BOUND,UY_BOUND,UZ_BOUND, &
                           TTRA_BOUND,TTRA_BOUND,TTRA_BOUND, &
                           VX,Vdummy,VZ,M)

               CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, TROT_BOUND, EROT)
               CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, TVIB_BOUND, EVIB)

               VY = UY_BOUND - FLX(S_NORM_YMAX,TTRA_BOUND,M) !!AAAAAAAAAAA

               DTFRAC = rf()*DT
               X = XMIN + (XMAX-XMIN)*rf() ! There was a bug here!
               Y = YMAX
               Z = ZMIN + (ZMAX-ZMIN)*rf()

               CALL CELL_FROM_POSITION(X,Y,  IC)

               ! Init a particle object and assign it to vector of particles
               CALL INIT_PARTICLE(X,Y,Z,VX,VY,VZ,EROT,EVIB,S_ID,IC,DTFRAC,  particleNOW)
               CALL ADD_PARTICLE_ARRAY(particleNOW, NP_PROC, particles)
            END DO
         END DO

      END IF

   END SUBROUTINE BOUNDARIES_INJECT
 
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE ADVECT -> Advects particles in the domain     !!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE ADVECT

      ! This subroutine advects the particles belonging to the processor.
      ! Particles are advected for a timestep DT. A temporary variable DTRIM is
      ! used: if a collision with a wall happens, the wall_collision subroutine 
      ! is called, the free flight time before collision is computed, and then 
      ! advection is performed for the remaining time. ! TO BE IMPLEMENTED!
      !
      ! After the advection, periodic BCs are applied, so that the periodic 
      ! coordinates stay into the domain boundaries.
      !
      ! Finally, if particles are out of the domain (and it happens only if 
      ! the periodicity wasn't active for some direction), remove them. 

      IMPLICIT NONE

      INTEGER      :: IP, IC, i, SOL, OLD_IC
      INTEGER      :: BOUNDCOLL, WALLCOLL, GOODSOL, EDGE_PG
      REAL(KIND=8) :: DTCOLL, TOTDTCOLL, CANDIDATE_DTCOLL, rfp
      REAL(KIND=8) :: COEFA, COEFB, COEFC, DELTA, SOL1, SOL2, ALPHA, BETA
      REAL(KIND=8), DIMENSION(2) :: TEST
      REAL(KIND=8), DIMENSION(4) :: NORMX, NORMY, XW, YW, ZW, BOUNDPOS
      ! REAL(KIND=8) :: XCOLL, YCOLL, ZCOLL
      REAL(KIND=8) :: VN, DX
      LOGICAL, DIMENSION(:), ALLOCATABLE :: REMOVE_PART
      REAL(KIND=8), DIMENSION(3) :: V_OLD, V_NEW
      REAL(KIND=8), DIMENSION(3) :: E, B
      REAL(KIND=8) :: V_NORM, V_PARA, V_PERP, VZ, VDUMMY, EROT, EVIB, VDOTN, WALL_TEMP
      INTEGER :: S_ID
      LOGICAL :: HASCOLLIDED
      REAL(KIND=8) :: XCOLL, YCOLL, COLLDIST, EDGE_X1, EDGE_Y1
      INTEGER, DIMENSION(:), ALLOCATABLE :: LOCAL_BOUNDARY_COLL_COUNT, LOCAL_WALL_COLL_COUNT
      REAL(KIND=8) :: WEIGHT_RATIO
      TYPE(PARTICLE_DATA_STRUCTURE) :: NEWparticle

      REAL(KIND=8) :: TOL

      TOL = 1e-15

      !E = [0.d0, 0.d0, 0.d0]
      B = [0.d0, 0.d0, 0.d0]


      NORMX = [ 1., -1., 0., 0. ]
      NORMY = [ 0., 0., 1., -1. ]

      XW = [ XMIN, XMAX, XMIN, XMAX ]
      YW = [ YMAX, YMIN, YMIN, YMAX ]
      ZW = [ 0., 0., 0., 0. ]

      BOUNDPOS = [ XMIN, XMAX, YMIN, YMAX ]

      ALLOCATE(REMOVE_PART(NP_PROC))
      
      ALLOCATE(LOCAL_BOUNDARY_COLL_COUNT(4*N_SPECIES))
      LOCAL_BOUNDARY_COLL_COUNT = 0
      ALLOCATE(LOCAL_WALL_COLL_COUNT(N_WALLS*N_SPECIES))
      LOCAL_WALL_COLL_COUNT = 0

      DO IP = 1, NP_PROC
         REMOVE_PART(IP) = .FALSE.

         ! Update velocity
         IC = particles(IP)%IC

         V_NEW(1) = particles(IP)%VX
         V_NEW(2) = particles(IP)%VY
         V_NEW(3) = particles(IP)%VZ

         IF (BOOL_PIC) THEN
            !PHIBAR_FIELD = 0.d0
            !EBAR_FIELD = 0.d0
            CALL APPLY_E_FIELD(IP, E)
            


            V_OLD(1) = particles(IP)%VX
            V_OLD(2) = particles(IP)%VY
            V_OLD(3) = particles(IP)%VZ

            CALL UPDATE_VELOCITY_BORIS(particles(IP)%DTRIM, V_OLD, V_NEW, &
            SPECIES(particles(IP)%S_ID)%CHARGE, SPECIES(particles(IP)%S_ID)%MOLECULAR_MASS, &
            E, B)

            ! Assign v^n to the particle, for simplicity
            !particles(IP)%VX = 0.5*(V_OLD(1) + V_NEW(1))
            !particles(IP)%VY = 0.5*(V_OLD(2) + V_NEW(2))
            !particles(IP)%VZ = 0.5*(V_OLD(3) + V_NEW(3))
            particles(IP)%VX = V_NEW(1)
            particles(IP)%VY = V_NEW(2)
            particles(IP)%VZ = V_NEW(3)
         END IF



         ! ! Forced electric field
         ! E = [3000.d0, 0.d0, 0.d0]
            


         ! V_OLD(1) = particles(IP)%VX
         ! V_OLD(2) = particles(IP)%VY
         ! V_OLD(3) = particles(IP)%VZ

         ! CALL UPDATE_VELOCITY_BORIS(DT, V_OLD, V_NEW, &
         ! SPECIES(particles(IP)%S_ID)%CHARGE, SPECIES(particles(IP)%S_ID)%MOLECULAR_MASS, &
         ! E, B)

         ! ! Assign v^n to the particle, for simplicity
         ! !particles(IP)%VX = 0.5*(V_OLD(1) + V_NEW(1))
         ! !particles(IP)%VY = 0.5*(V_OLD(2) + V_NEW(2))
         ! !particles(IP)%VZ = 0.5*(V_OLD(3) + V_NEW(3))
         ! particles(IP)%VX = V_NEW(1)
         ! particles(IP)%VY = V_NEW(2)
         ! particles(IP)%VZ = V_NEW(3)

         ! ! End forced electric field.



         HASCOLLIDED = .FALSE.
         TOTDTCOLL = 0.
         DO WHILE (particles(IP)%DTRIM .GT. 0.) ! Repeat the procedure until step is done

            DTCOLL = particles(IP)%DTRIM ! Looking for collisions within the remaining time
            ! ______ ADVECTION ______

            IF (GRID_TYPE == UNSTRUCTURED) THEN
               !WRITE(*,*) 'Moving particle ', IP, ' for ', DTCOLL, ' s. Position: ', particles(IP)%X, particles(IP)%Y,&
               !' velocity: ', particles(IP)%VX, particles(IP)%VY
               ! For unstructured, we only need to check the boundaries of the cell.
               BOUNDCOLL = -1
               DO I = 1, 3
                  
                  VN = particles(IP)%VX * U2D_GRID%EDGE_NORMAL(IC,I,1) &
                     + particles(IP)%VY * U2D_GRID%EDGE_NORMAL(IC,I,2)
                  ! Compute the distance from the boundary
                  DX = (U2D_GRID%NODE_COORDS(U2D_GRID%CELL_NODES(IC,I),1) - particles(IP)%X) * U2D_GRID%EDGE_NORMAL(IC,I,1) &
                     + (U2D_GRID%NODE_COORDS(U2D_GRID%CELL_NODES(IC,I),2) - particles(IP)%Y) * U2D_GRID%EDGE_NORMAL(IC,I,2)
                  ! Check if a collision happens (sooner than previously calculated)
                  IF (VN .GE. 0. .AND. VN * DTCOLL .GT. DX) THEN

                     DTCOLL = DX/VN
                     BOUNDCOLL = I
                     TOTDTCOLL = TOTDTCOLL + DTCOLL  
                     HASCOLLIDED = .TRUE.     

                  END IF

               END DO

               IF (BOUNDCOLL .NE. -1) THEN
                  IF (particles(IP)%Y == 0.d0 .AND. DTCOLL == 0.d0) WRITE(*,*) 'Here 1.'
                  CALL MOVE_PARTICLE(IP, DTCOLL)
                  particles(IP)%DTRIM = particles(IP)%DTRIM - DTCOLL

                  ! Move to new cell
                  IF (U2D_GRID%CELL_NEIGHBORS(IC, BOUNDCOLL) == -1) THEN
                     EDGE_PG = U2D_GRID%CELL_EDGES_PG(IC, BOUNDCOLL)
                     IF (EDGE_PG .NE. -1) THEN
                        ! Apply particle boundary condition
                        IF (GRID_BC(EDGE_PG)%PARTICLE_BC == SPECULAR) THEN
                           IF (GRID_BC(EDGE_PG)%REACT) THEN
                              CALL WALL_REACT(IP, REMOVE_PART(IP))
                           END IF
                           
                           VDOTN = particles(IP)%VX*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,1) &
                                 + particles(IP)%VY*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,2)
                           particles(IP)%VX = particles(IP)%VX - 2.*VDOTN*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,1)
                           particles(IP)%VY = particles(IP)%VY - 2.*VDOTN*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,2)
                        ELSE IF (GRID_BC(EDGE_PG)%PARTICLE_BC == DIFFUSE) THEN
                           IF (GRID_BC(EDGE_PG)%REACT) THEN
                              CALL WALL_REACT(IP, REMOVE_PART(IP))
                           END IF

                           S_ID = particles(IP)%S_ID
                           WALL_TEMP = GRID_BC(EDGE_PG)%WALL_TEMP
                           CALL MAXWELL(0.d0, 0.d0, 0.d0, &
                           WALL_TEMP, WALL_TEMP, WALL_TEMP, &
                           VDUMMY, V_PARA, VZ, SPECIES(S_ID)%MOLECULAR_MASS)

                           CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, WALL_TEMP, EROT)
                           CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, WALL_TEMP, EVIB)
                                          
                           V_PERP = FLX(0.d0, WALL_TEMP, SPECIES(S_ID)%MOLECULAR_MASS)

                           particles(IP)%VX = - V_PERP*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,1) &
                                            - V_PARA*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,2)
                           particles(IP)%VY = - V_PERP*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,2) &
                                            + V_PARA*U2D_GRID%EDGE_NORMAL(IC,BOUNDCOLL,1)
                           particles(IP)%VZ = VZ
                           particles(IP)%EROT = EROT
                           particles(IP)%EVIB = EVIB
                        ELSE
                           REMOVE_PART(IP) = .TRUE.
                           particles(IP)%DTRIM = 0.d0
                        END IF
                     ELSE
                        REMOVE_PART(IP) = .TRUE.
                        particles(IP)%DTRIM = 0.d0
                     END IF
                  ELSE
                     particles(IP)%IC = U2D_GRID%CELL_NEIGHBORS(IC, BOUNDCOLL)
                     IC = particles(IP)%IC
                     !WRITE(*,*) 'moved particle to cell: ', IC
                  END IF
               ELSE
                  IF (particles(IP)%Y == 0.d0 .AND. DTCOLL == 0.d0) WRITE(*,*) 'Here 2.'
                  CALL MOVE_PARTICLE(IP, particles(IP)%DTRIM)
                  particles(IP)%DTRIM = 0.d0
               END IF

            ELSE ! Grid type is rectilinear
               BOUNDCOLL = -1
               DO i = 1, 4 ! Check collisions with boundaries (xmin, xmax, ymin, ymax)
                  IF (AXI) THEN
                     ! We are axisymmetric. Check is more complicated.
                     CANDIDATE_DTCOLL = DTCOLL
                     
                     IF (i==1 .OR. i==2) THEN
                        ! Vertical wall
                        SOL1 = (BOUNDPOS(i)-particles(IP)%X)/particles(IP)%VX
                        IF (SOL1 >= 0 .AND. SOL1 < DTCOLL) THEN
                           GOODSOL = 1
                           TEST(1) = SOL1
                        ELSE
                           GOODSOL = 0
                        END IF
                     ELSE
                        ! Horizontal boundary
                        COEFA = particles(IP)%VY**2 + particles(IP)%VZ**2
                        COEFB = particles(IP)%Y * particles(IP)%VY
                        COEFC = particles(IP)%Y**2 - BOUNDPOS(i)**2
                        DELTA = COEFB*COEFB-COEFA*COEFC
                        IF (DELTA .GE. 0) THEN
                        ! Compute the solutions, check if they are any good and, in case, order them to be checked further.
                           SOL1 = (-COEFB - SQRT(DELTA))/COEFA
                           SOL2 = (-COEFB + SQRT(DELTA))/COEFA
                           IF (SOL1 >= 0 .AND. SOL1 < DTCOLL) THEN
                              IF (SOL2 >= 0 .AND. SOL2 < DTCOLL) THEN
                                 GOODSOL = 2
                                 IF (SOL1 <= SOL2) THEN
                                    TEST(1) = SOL1
                                    TEST(2) = SOL2
                                 ELSE
                                    TEST(1) = SOL2
                                    TEST(2) = SOL1
                                 END IF
                              ELSE
                                 GOODSOL = 1
                                 TEST(1) = SOL1
                              ENDIF
                           ELSE
                              IF (SOL2 >= 0 .AND. SOL2 < DTCOLL) THEN
                                 GOODSOL = 1
                                 TEST(1) = SOL2
                              ELSE
                                 GOODSOL = 0
                              END IF 
                           END IF
                        ELSE
                           GOODSOL = 0
                        END IF
                     END IF

                     ! Now further checks for each of the good solutions:
                     ! - if the velocity at collision time is actually towards the surface
                     ! - if the collision point is within the extremes of the segment
                     ! Note: this requires moving the particle to the collision point and then moving back.
                     IF (GOODSOL /= 0) THEN
                        DO SOL = 1, GOODSOL
                           CALL MOVE_PARTICLE(IP, TEST(SOL))
                           IF ((particles(IP)%VX*NORMX(i) + particles(IP)%VY*NORMY(i)) < 0) THEN
                              ! Collision happens!
                              DTCOLL = TEST(SOL)
                              BOUNDCOLL = i    
                              TOTDTCOLL = TOTDTCOLL + DTCOLL  
                              HASCOLLIDED = .TRUE.
                              IF (BOUNDCOLL == 3) WRITE(*,*) "Collision with axis!"
                           END IF
                           CALL MOVE_PARTICLE(IP, -TEST(SOL))
                        END DO
                     END IF

                     

                  ELSE
                     ! We are not axisymmetric
                     ! Compute the velocity normal to the boundary
                     VN = -(particles(IP)%VX * NORMX(i) + particles(IP)%VY * NORMY(i))
                     ! Compute the distance from the boundary
                     DX = (particles(IP)%X - XW(i)) * NORMX(i) + (particles(IP)%Y - YW(i)) * NORMY(i)
                     ! Check if a collision happens (sooner than previously calculated)
                     IF (VN .GE. 0. .AND. VN * DTCOLL .GT. DX) THEN
                        
                        ! Find candidate collision point (don't need this for boundaries)
                        ! XCOLL = particles(IP)%X + particles(IP)%VX * DTCOLL 
                        ! YCOLL = particles(IP)%Y + particles(IP)%VY * DTCOLL
                        ! ZCOLL = particles(IP)%Z + particles(IP)%VZ * DTCOLL

                        DTCOLL = DX/VN
                        BOUNDCOLL = i    
                        TOTDTCOLL = TOTDTCOLL + DTCOLL  
                        HASCOLLIDED = .TRUE.               

                     END IF
                  END IF
               END DO

               

               ! Check collisions with surfaces
               ! If earlier than dtcoll remember to set BOUNDCOLL to -1 and the new dtcoll
               WALLCOLL = -1
               DO i = 1, N_WALLS
                  IF (AXI) THEN
                     ! We are axisymmetric
                     CANDIDATE_DTCOLL = DTCOLL
                     ! Compute auxiliary parameters
                     IF (WALLS(i)%X1 == WALLS(i)%X2) THEN
                        ! Vertical wall
                        SOL1 = (WALLS(i)%X1-particles(IP)%X)/particles(IP)%VX
                        IF (SOL1 >= 0 .AND. SOL1 < DTCOLL) THEN
                           GOODSOL = 1
                           TEST(1) = SOL1
                        ELSE
                           GOODSOL = 0
                        END IF
                     ELSE
                        ! Non-vertical wall
                        ALPHA = (WALLS(i)%Y2-WALLS(i)%Y1)/(WALLS(i)%X2-WALLS(i)%X1)
                        BETA  = (particles(IP)%X - WALLS(i)%X1)*ALPHA

                        COEFA = particles(IP)%VY**2 + particles(IP)%VZ**2 - ALPHA*ALPHA*particles(IP)%VX**2
                        COEFB = particles(IP)%Y * particles(IP)%VY - (BETA + WALLS(i)%Y1)*ALPHA*particles(IP)%VX
                        COEFC = particles(IP)%Y**2 - (BETA + WALLS(i)%Y1)**2
                        DELTA = COEFB*COEFB-COEFA*COEFC
                        IF (DELTA .GE. 0) THEN
                           ! Compute the solutions, check if they are any good and, in case, order them to be checked further.
                           SOL1 = (-COEFB - SQRT(DELTA))/COEFA
                           SOL2 = (-COEFB + SQRT(DELTA))/COEFA
                           IF (SOL1 >= 0 .AND. SOL1 < DTCOLL .AND. BETA+ALPHA*particles(IP)%VX*SOL1+WALLS(i)%Y1 >= 0) THEN
                              IF (SOL2 >= 0 .AND. SOL2 < DTCOLL .AND. BETA+ALPHA*particles(IP)%VX*SOL2+WALLS(i)%Y1 >= 0) THEN
                                 GOODSOL = 2
                                 IF (SOL1 <= SOL2) THEN
                                    TEST(1) = SOL1
                                    TEST(2) = SOL2
                                 ELSE
                                    TEST(1) = SOL2
                                    TEST(2) = SOL1
                                 END IF
                              ELSE
                                 GOODSOL = 1
                                 TEST(1) = SOL1
                              ENDIF
                           ELSE
                              IF (SOL2 >= 0 .AND. SOL2 < DTCOLL .AND. BETA+ALPHA*particles(IP)%VX*SOL2+WALLS(i)%Y1 >= 0) THEN
                                 GOODSOL = 1
                                 TEST(1) = SOL2
                              ELSE
                                 GOODSOL = 0
                              END IF 
                           END IF
                        ELSE
                           GOODSOL = 0
                        END IF
                     END IF

                     ! Now further checks for each of the good solutions:
                     ! - if the velocity at collision time is actually towards the surface
                     ! - if the collision point is within the extremes of the segment
                     ! Note: this requires moving the particle to the collision point and then moving back.
                     IF (GOODSOL /= 0) THEN
                        DO SOL = 1, GOODSOL
                           CALL MOVE_PARTICLE(IP, TEST(SOL))
                           IF ((particles(IP)%VX*WALLS(i)%NORMX + particles(IP)%VY*WALLS(i)%NORMY) < 0) THEN

                              COLLDIST = ((particles(IP)%X-WALLS(i)%X1)*(WALLS(i)%X2-WALLS(i)%X1) &
                                       + (particles(IP)%Y-WALLS(i)%Y1)*(WALLS(i)%Y2-WALLS(i)%Y1)) &
                                       / ((WALLS(i)%X2-WALLS(i)%X1)**2 + (WALLS(i)%Y2-WALLS(i)%Y1)**2)
                              IF ((COLLDIST .GE. 0) .AND. (COLLDIST .LE. 1)) THEN
                                 ! Collision happens!
                                 DTCOLL = TEST(SOL)
                                 BOUNDCOLL = -1
                                 WALLCOLL = i   
                                 TOTDTCOLL = TOTDTCOLL + DTCOLL  
                                 HASCOLLIDED = .TRUE.
                              END IF
                           END IF
                           CALL MOVE_PARTICLE(IP, -TEST(SOL))
                        END DO
                     END IF


                  ELSE
                     ! We are not axisymmetric
                     ! Compute the velocity normal to the surface
                     VN = -(particles(IP)%VX * WALLS(i)%NORMX + particles(IP)%VY * WALLS(i)%NORMY)
                     ! Compute the distance from the boundary
                     DX = (particles(IP)%X - WALLS(i)%X1) * WALLS(i)%NORMX + (particles(IP)%Y - WALLS(i)%Y1) * WALLS(i)%NORMY
                     ! Check if a collision happens (sooner than previously calculated)
                     IF (DX .GE. 0. .AND. VN * DTCOLL .GE. DX) THEN
                        
                        CANDIDATE_DTCOLL = DX/VN
                        ! Find candidate collision point
                        XCOLL = particles(IP)%X + particles(IP)%VX * CANDIDATE_DTCOLL 
                        YCOLL = particles(IP)%Y + particles(IP)%VY * CANDIDATE_DTCOLL
                        COLLDIST = ((XCOLL-WALLS(i)%X1)*(WALLS(i)%X2-WALLS(i)%X1)+(YCOLL-WALLS(i)%Y1)*(WALLS(i)%Y2-WALLS(i)%Y1))/ &
                        ((WALLS(i)%X2-WALLS(i)%X1)**2 + (WALLS(i)%Y2-WALLS(i)%Y1)**2)
                        IF ((COLLDIST .GE. 0) .AND. (COLLDIST .LE. 1)) THEN
                           BOUNDCOLL = -1
                           WALLCOLL = i
                           DTCOLL = CANDIDATE_DTCOLL
                           TOTDTCOLL = TOTDTCOLL + DTCOLL
                           HASCOLLIDED = .TRUE.
                        END IF
                     END IF
                  END IF
               END DO


               IF (BOUNDCOLL .NE. -1) THEN
                  ! Collision with a boundary
                  ! Tally the collision
                  LOCAL_BOUNDARY_COLL_COUNT(BOUNDCOLL+4*(particles(IP)%S_ID-1)) = &
                  LOCAL_BOUNDARY_COLL_COUNT(BOUNDCOLL+4*(particles(IP)%S_ID-1)) + 1

                  IF (BOOL_PERIODIC(BOUNDCOLL)) THEN

                     CALL MOVE_PARTICLE(IP, DTCOLL)
                     SELECT CASE (BOUNDCOLL)
                        CASE (1)
                           particles(IP)%X = particles(IP)%X + XMAX - XMIN
                        CASE (2)
                           particles(IP)%X = particles(IP)%X - XMAX + XMIN
                        CASE (3)
                           particles(IP)%Y = particles(IP)%Y + YMAX - YMIN
                        CASE (4)
                           particles(IP)%Y = particles(IP)%Y - YMAX + YMIN
                     END SELECT
                     particles(IP)%DTRIM = particles(IP)%DTRIM - DTCOLL

                  ELSE IF (BOOL_SPECULAR(BOUNDCOLL)) THEN
                  
                     CALL MOVE_PARTICLE(IP, DTCOLL)
                     SELECT CASE (BOUNDCOLL)
                        CASE (1)
                           particles(IP)%VX = - particles(IP)%VX
                        CASE (2)
                           particles(IP)%VX = - particles(IP)%VX
                        CASE (3)
                           particles(IP)%VY = - particles(IP)%VY
                        CASE (4)
                           particles(IP)%VY = - particles(IP)%VY
                     END SELECT
                     particles(IP)%DTRIM = particles(IP)%DTRIM - DTCOLL

                     IF (BOOL_REACT(BOUNDCOLL)) THEN
                        CALL WALL_REACT(IP, REMOVE_PART(IP))
                     END IF

                  ELSE IF (BOOL_DIFFUSE(BOUNDCOLL)) THEN

                     CALL MOVE_PARTICLE(IP, DTCOLL)
                     particles(IP)%DTRIM = particles(IP)%DTRIM - DTCOLL
                     IF (BOOL_REACT(BOUNDCOLL)) THEN
                        CALL WALL_REACT(IP, REMOVE_PART(IP))
                     END IF
                     IF (.NOT. REMOVE_PART(IP)) THEN
                        S_ID = particles(IP)%S_ID
                        CALL MAXWELL(0.d0, 0.d0, 0.d0, &
                        BOUNDTEMP, BOUNDTEMP, BOUNDTEMP, &
                        VDUMMY, V_PERP, VZ, SPECIES(S_ID)%MOLECULAR_MASS)

                        CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, BOUNDTEMP, EROT)
                        CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, BOUNDTEMP, EVIB)
                                       
                        V_NORM = FLX(0.d0, BOUNDTEMP, SPECIES(S_ID)%MOLECULAR_MASS)

                        particles(IP)%VX = V_NORM*NORMX(BOUNDCOLL) - V_PERP*NORMY(BOUNDCOLL)
                        particles(IP)%VY = V_PERP*NORMX(BOUNDCOLL) + V_NORM*NORMY(BOUNDCOLL)
                        particles(IP)%VZ = VZ
                        particles(IP)%EROT = EROT
                        particles(IP)%EVIB = EVIB

                     END IF

                  ELSE

                     REMOVE_PART(IP) = .TRUE.
                     particles(IP)%DTRIM = 0.

                  END IF
               ELSE IF (WALLCOLL .NE. -1) THEN
                  ! Collision with a wall
                  ! Tally the collision
                  LOCAL_WALL_COLL_COUNT(WALLCOLL+N_WALLS*(particles(IP)%S_ID-1)) = &
                  LOCAL_WALL_COLL_COUNT(WALLCOLL+N_WALLS*(particles(IP)%S_ID-1)) + 1

                  IF (WALLS(WALLCOLL)%SPECULAR) THEN
                     rfp = rf()
                     IF (WALLS(WALLCOLL)%POROUS .AND. rfp .LE. WALLS(WALLCOLL)%TRANSMISSIVITY) THEN

                        REMOVE_PART(IP) = .TRUE.
                        particles(IP)%DTRIM = 0.

                     ELSE

                        CALL MOVE_PARTICLE(IP, DTCOLL)
                        !WRITE(*,*) "Specular reflection! Velocity before: ",  particles(IP)%VX, ", ", particles(IP)%VY
                        VDOTN = particles(IP)%VX*WALLS(WALLCOLL)%NORMX+particles(IP)%VY*WALLS(WALLCOLL)%NORMY
                        particles(IP)%VX = particles(IP)%VX - 2.*VDOTN*WALLS(WALLCOLL)%NORMX
                        particles(IP)%VY = particles(IP)%VY - 2.*VDOTN*WALLS(WALLCOLL)%NORMY
                        !WRITE(*,*) "Normal:  ",  WALLS(WALLCOLL)%NORMX, ", ", WALLS(WALLCOLL)%NORMY
                        !WRITE(*,*) "Specular reflection! Velocity after:  ",  particles(IP)%VX, ", ", particles(IP)%VY
                        particles(IP)%DTRIM = particles(IP)%DTRIM - DTCOLL

                        IF (WALLS(WALLCOLL)%REACT) THEN
                           CALL WALL_REACT(IP, REMOVE_PART(IP))
                        END IF

                     END IF
                  ELSE IF (WALLS(WALLCOLL)%DIFFUSE) THEN
                     rfp = rf()
                     IF (WALLS(WALLCOLL)%POROUS .AND. rfp .LE. WALLS(WALLCOLL)%TRANSMISSIVITY) THEN

                        REMOVE_PART(IP) = .TRUE.
                        particles(IP)%DTRIM = 0.
                        
                     ELSE
                           
                        CALL MOVE_PARTICLE(IP, DTCOLL)
                        particles(IP)%DTRIM = particles(IP)%DTRIM - DTCOLL
                        IF (WALLS(WALLCOLL)%REACT) THEN
                           CALL WALL_REACT(IP, REMOVE_PART(IP))
                        END IF
                        IF (.NOT. REMOVE_PART(IP)) THEN
                           S_ID = particles(IP)%S_ID
                           CALL MAXWELL(0.d0, 0.d0, 0.d0, &
                           WALLS(WALLCOLL)%TEMP, WALLS(WALLCOLL)%TEMP, WALLS(WALLCOLL)%TEMP, &
                           VDUMMY, V_PERP, VZ, SPECIES(S_ID)%MOLECULAR_MASS)

                           CALL INTERNAL_ENERGY(SPECIES(S_ID)%ROTDOF, WALLS(WALLCOLL)%TEMP, EROT)
                           CALL INTERNAL_ENERGY(SPECIES(S_ID)%VIBDOF, WALLS(WALLCOLL)%TEMP, EVIB)
                                          
                           V_NORM = FLX(0.d0, WALLS(WALLCOLL)%TEMP, SPECIES(S_ID)%MOLECULAR_MASS)

                           particles(IP)%VX = V_NORM*WALLS(WALLCOLL)%NORMX - V_PERP*WALLS(WALLCOLL)%NORMY
                           particles(IP)%VY = V_PERP*WALLS(WALLCOLL)%NORMX + V_NORM*WALLS(WALLCOLL)%NORMY
                           particles(IP)%VZ = VZ
                           particles(IP)%EROT = EROT
                           particles(IP)%EVIB = EVIB

                        END IF
                     END IF

                  ELSE

                     REMOVE_PART(IP) = .TRUE.
                     particles(IP)%DTRIM = 0.

                  END IF

               ELSE
                  ! No collision in this timestep
                  CALL MOVE_PARTICLE(IP, particles(IP)%DTRIM)
                  particles(IP)%DTRIM = 0.

               END IF


               ! Axisymmetric velocity rotation already performed in MOVE_PARTICLE()

         
               ! _______ CHECK WHERE PARTICLE ENDED UP _______

               ! ++++++++ Check if particle is still in the domain ++++++++++++
               !IF (particles(IP)%X .GE. XMIN .AND. particles(IP)%X .LE. XMAX .AND. & 
               !    particles(IP)%Y .GE. YMIN .AND. particles(IP)%Y .LE. YMAX .AND. &
               !    particles(IP)%Z .GE. ZMIN .AND. particles(IP)%Z .LE. ZMAX) THEN   ! Check that the particle is still in the domain
         
                  ! Compute the index of the cell in which the particle ended up
                  !CALL CELL_FROM_POSITION(particles(IP)%X, particles(IP)%Y, IC)
                  !particles(IP)%IC = IC
         
                  !DTRIM = 0.E0 ! Timestep is over.
      
               ! +++++++++ Particle crossed domain boundaries ++++++++
               !ELSE

                  ! CALL IMPACT_BOUNDARY(IP, DTRIM) 
               !   DTRIM = 0.E0 ! TMP TMP TMP TMP TMP TMP TMP TMP TMP
               !END IF

            END IF

         END DO ! WHILE (DTRIM .GT. 0.)

            ! _______ APPLY Z PERIODIC BCs ________

            ! Z we should be able to do this a posteriori (remember it could be more than one depth length out!)
         IF (BOOL_Z_PERIODIC) THEN
         
            DO WHILE (particles(IP)%Z .GT. ZMAX)
               particles(IP)%Z = ZMIN + (particles(IP)%Z - ZMAX)
            END DO
            DO WHILE (particles(IP)%Z .LT. ZMIN) 
               particles(IP)%Z = ZMAX + (particles(IP)%Z - ZMIN)
            END DO
      
         END IF 

         particles(IP)%DTRIM = DT ! For the next timestep.

         !IF (HASCOLLIDED) THEN
         !   V_OLD(1) = particles(IP)%VX
         !   V_OLD(2) = particles(IP)%VY
         !   V_OLD(3) = particles(IP)%VZ
            !Propagate v_coll to v^{n+1/2}
            !Consistent: does not change for neutral particles.
            !Also does not change is collision happens at DT/2
            !CALL UPDATE_VELOCITY_BORIS(DT/2., V_OLD, V_NEW, &
            !SPECIES(particles(IP)%S_ID)%CHARGE, SPECIES(particles(IP)%S_ID)%MOLECULAR_MASS, &
            !E, B)
         !END IF
         !particles(IP)%VX = V_NEW(1)
         !particles(IP)%VY = V_NEW(2)
         !particles(IP)%VZ = V_NEW(3)

      END DO ! End loop: DO IP = 1,NP_PROC

      ! ==============
      ! ========= Now remove particles that are out of the domain and reorder the array. 
      ! ========= Do this in the end of the advection step, since reordering the array 
      ! ========= mixes the particles.
      ! ==============

      IP = NP_PROC
      DO WHILE (IP .GE. 1)

         ! Is particle IP out of the domain? Then remove it!
         IF (REMOVE_PART(IP)) THEN
            CALL REMOVE_PARTICLE_ARRAY(IP, particles, NP_PROC)
         ELSE IF (GRID_TYPE .NE. UNSTRUCTURED) THEN
            CALL CELL_FROM_POSITION(particles(IP)%X, particles(IP)%Y, IC)
            OLD_IC = particles(IP)%IC
            particles(IP)%IC = IC
            ! If cell-based particle weight has changed,
            IF (BOOL_RADIAL_WEIGHTING .AND. (IC .NE. OLD_IC)) THEN
               WEIGHT_RATIO = CELL_FNUM(OLD_IC)/CELL_FNUM(IC)
               ! If the weight has increased, the particle may be removed
               IF (WEIGHT_RATIO .LT. 1.d0) THEN
                  rfp = rf()
                  IF (WEIGHT_RATIO .LT. rfp) CALL REMOVE_PARTICLE_ARRAY(IP, particles, NP_PROC)
               ELSE IF (WEIGHT_RATIO .GT. 1.d0) THEN
               ! If the weight has decreased, more particles may be added
                  rfp = rf()
                  DO WHILE ((WEIGHT_RATIO - 1.) .GT. rfp)
                     CALL INIT_PARTICLE(particles(IP)%X, particles(IP)%Y, particles(IP)%Z, &
                     particles(IP)%VX, particles(IP)%VY,particles(IP)%VZ, &
                     particles(IP)%EROT,particles(IP)%EVIB,particles(IP)%S_ID,IC,DT,NEWparticle)
                     CALL ADD_PARTICLE_ARRAY(NEWparticle, NP_PROC, particles)
                     WEIGHT_RATIO = WEIGHT_RATIO - 1.
                  END DO
               END IF
            END IF
         END IF

         IP = IP - 1

      END DO

      DEALLOCATE(REMOVE_PART)


      ! Tally surface collisions from all processes
      CALL MPI_REDUCE(LOCAL_BOUNDARY_COLL_COUNT, BOUNDARY_COLL_COUNT, 4*N_SPECIES, MPI_INTEGER, MPI_SUM, 0, &
      MPI_COMM_WORLD, ierr)

      DEALLOCATE(LOCAL_BOUNDARY_COLL_COUNT)
      
      CALL MPI_REDUCE(LOCAL_WALL_COLL_COUNT, WALL_COLL_COUNT, N_WALLS*N_SPECIES, MPI_INTEGER, MPI_SUM, 0, &
      MPI_COMM_WORLD, ierr)

      DEALLOCATE(LOCAL_WALL_COLL_COUNT)

   END SUBROUTINE ADVECT


   SUBROUTINE UPDATE_VELOCITY_BORIS(DT, V_OLD, V_NEW, CHARGE, MASS, E, B)

      IMPLICIT NONE

      REAL(KIND=8), DIMENSION(3), INTENT(OUT) :: V_NEW
      REAL(KIND=8), DIMENSION(3), INTENT(IN) :: V_OLD, E, B
      REAL(KIND=8), DIMENSION(3) :: V_MINUS, V_PLUS, V_PRIME, T, S
      REAL(KIND=8), INTENT(IN) :: DT, CHARGE, MASS
      REAL(KIND=8) :: COULOMBCHARGE

      COULOMBCHARGE = CHARGE * QE
      V_MINUS = V_OLD + 0.5*COULOMBCHARGE*E/MASS*DT

      T = 0.5*COULOMBCHARGE*B/MASS*DT
      V_PRIME = V_MINUS + CROSS(V_MINUS, T)
      S = 2.*T/(1.+( T(1)*T(1) + T(2)*T(2) + T(3)*T(3) ))
      V_PLUS = V_MINUS + CROSS(V_PRIME, S)

      V_NEW = V_PLUS + 0.5*COULOMBCHARGE*E/MASS*DT

   END SUBROUTINE

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE MOVE_PARTICLE -> Move the particles !!!!!!!!!!!!!!!!!!!!!!!!!!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE MOVE_PARTICLE(IP, TIME)

      ! Moves particle with index IP for time TIME.
      ! For now simply rectilinear movement, will have to include Lorentz's force

      IMPLICIT NONE

      INTEGER, INTENT(IN)      :: IP
      REAL(KIND=8), INTENT(IN) :: TIME
      REAL(KIND=8)             :: SINTHETA, COSTHETA, VZ, VY, R

      ! WRITE(*,*) "Moving particle ", IP, " for time interval ", TIME

      IF (AXI) THEN
         
         particles(IP)%X = particles(IP)%X + particles(IP)%VX * TIME
         particles(IP)%Z = 0.d0
         R = SQRT((particles(IP)%Y + particles(IP)%VY*TIME)**2 + (particles(IP)%VZ*TIME)**2)
         ! Rotate velocity vector back to x-y plane.
         SINTHETA = particles(IP)%VZ*TIME / R
         COSTHETA = SIGN(SQRT(1.-SINTHETA*SINTHETA), particles(IP)%Y + particles(IP)%VY*TIME)

         IF (GRID_TYPE == UNSTRUCTURED) THEN
            particles(IP)%Y = particles(IP)%Y + particles(IP)%VY * TIME
         ELSE
            particles(IP)%Y = R
         END IF

         IF (particles(IP)%Y .NE. 0.d0) THEN
            VZ = particles(IP)%VZ
            VY = particles(IP)%VY
            particles(IP)%VZ = COSTHETA*VZ - SINTHETA*VY
            particles(IP)%VY = SINTHETA*VZ + COSTHETA*VY
         END IF
         
      ELSE
         particles(IP)%X = particles(IP)%X + particles(IP)%VX * TIME
         particles(IP)%Y = particles(IP)%Y + particles(IP)%VY * TIME
         particles(IP)%Z = particles(IP)%Z + particles(IP)%VZ * TIME
      END IF

   END SUBROUTINE MOVE_PARTICLE


   SUBROUTINE WALL_REACT(IP, REMOVE)
      
      IMPLICIT NONE

      INTEGER, INTENT(IN) :: IP
      LOGICAL, INTENT(OUT) :: REMOVE
      INTEGER :: JS, JR, JP
      REAL(KIND=8) :: PROB_SCALE, VEL_SCALE

      JS = particles(IP)%S_ID
      PROB_SCALE = 1.
      REMOVE = .FALSE.
      DO JR = 1, N_WALL_REACTIONS
         IF (WALL_REACTIONS(JR)%R_SP_ID == JS) THEN
            IF ( rf() .LE. WALL_REACTIONS(JR)%PROB/PROB_SCALE ) THEN
               
               IF (WALL_REACTIONS(JR)%N_PROD == 0) THEN
                  REMOVE = .TRUE.
                  particles(IP)%DTRIM = 0.
               ELSE IF (WALL_REACTIONS(JR)%N_PROD == 1) THEN
                  JP = WALL_REACTIONS(JR)%P1_SP_ID
                  particles(IP)%S_ID = JP
                  VEL_SCALE = SPECIES(JS)%MOLECULAR_MASS/SPECIES(JP)%MOLECULAR_MASS
                  particles(IP)%VX = particles(IP)%VX*VEL_SCALE
                  particles(IP)%VY = particles(IP)%VY*VEL_SCALE
                  particles(IP)%VZ = particles(IP)%VZ*VEL_SCALE
               ELSE
                  CALL ERROR_ABORT('Number of products in wall reaction not supported.')
               END IF

            ELSE
               PROB_SCALE = PROB_SCALE - WALL_REACTIONS(JR)%PROB
            END IF

         END IF
      END DO


   END SUBROUTINE WALL_REACT

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE MCC_COLLISIONS -> perform MCC collisions !!!!!!!!!!!!!!!!!!!!!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE MCC_COLLISIONS

      ! Performs MCC collisions: for each particle in the current process ID, computes the probability of 
      ! colliding with a background species, and (in case) performs the collision. 
      ! 
      ! There is no need to consider cells for these collisions. The neutrals density is for the
      ! moment uniform in space. In the future, we may associate it to the cells...
      ! NOTE: Eventually this procedure could be merged with similar procedures in collisions.f90

      IMPLICIT NONE

      INTEGER      :: JP1, JP2, JR, I, J, SP_ID1, SP_ID2, P1_SP_ID, P2_SP_ID, P3_SP_ID, NP_PROC_INITIAL
      REAL(KIND=8) :: P_COLL, PTCE, rfp
      REAL(KIND=8) :: SIGMA, OMEGA, CREF, ALPHA, FRAC
      REAL(KIND=8) :: PI2
      REAL(KIND=8), DIMENSION(3) :: C1, C2, GREL, W
      REAL(KIND=8) :: GX, GY, GZ, G
      REAL(KIND=8) :: COSCHI, SINCHI, THETA, COSTHETA, SINTHETA
      REAL(KIND=8) :: VR2, VR, MRED, M1, M2, COSA, SINA, BB
      REAL(KIND=8) :: TRDOF, PROT1, PROT2, PVIB1, PVIB2, EI, ETR, ECOLL, TOTDOF, EA, EROT, EVIB
      LOGICAL :: SKIP
      TYPE(PARTICLE_DATA_STRUCTURE) :: NEWparticle

      PI2 = 2*PI

      TIMESTEP_COLL = 0

      NP_PROC_INITIAL = NP_PROC
      DO JP1 = 1,NP_PROC_INITIAL
         SP_ID1 = particles(JP1)%S_ID

         DO J = 1, MIXTURES(MCC_BG_MIX)%N_COMPONENTS
            SP_ID2 = MIXTURES(MCC_BG_MIX)%COMPONENTS(J)%ID
            
            !SIGMA = PI * (0.5 * (SPECIES(SP_ID1)%DIAM + SPECIES(SP_ID2)%DIAM))**2
            !OMEGA = 0.5 * (SPECIES(SP_ID1)%OMEGA + SPECIES(SP_ID2)%OMEGA)
            CREF = VSS_GREFS(SP_ID1, SP_ID2)
            !ALPHA = 0.5 * (SPECIES(SP_ID1)%ALPHA + SPECIES(SP_ID2)%ALPHA)
            SIGMA = VSS_SIGMAS(SP_ID1, SP_ID2)
            OMEGA = VSS_OMEGAS(SP_ID1, SP_ID2)
            ALPHA = VSS_ALPHAS(SP_ID1, SP_ID2)
            
            ! Sample the velocity of second collision partner, that would be in the MCC backgorund
            ! This may bias collisions towards higher temperatures of particle 2!
            CALL MAXWELL(0.d0, 0.d0, 0.d0, &
            MCC_BG_TTRA, MCC_BG_TTRA, MCC_BG_TTRA, &
            C2(1), C2(2), C2(3), SPECIES(SP_ID2)%MOLECULAR_MASS)

            ! Compute the real relative velocity
            VR2 = (C2(1) - particles(JP1)%VX)**2 + &
            (C2(2) - particles(JP1)%VY)**2 + &
            (C2(3) - particles(JP1)%VZ)**2 

            VR = SQRT(VR2)
            

            ! Compute collision probability
            FRAC = MIXTURES(MCC_BG_MIX)%COMPONENTS(J)%MOLFRAC
            P_COLL = 1 - exp(-DT*MCC_BG_DENS*FRAC*VR*SIGMA*(VR/CREF)**(1.-2.*OMEGA))

            ! Try the collision
            IF (rf() < P_COLL) THEN ! Collision happens

               TIMESTEP_COLL = TIMESTEP_COLL + 1

               ! Rimuovere commento per avere avviso
               IF (P_COLL .GT. 1.) THEN
                  WRITE(*,*) 'Attention => this was a bad MCC collision!!!'
               END IF

               C1(1) = particles(JP1)%VX
               C1(2) = particles(JP1)%VY
               C1(3) = particles(JP1)%VZ

               ! Actually create the second collision partner
               CALL INTERNAL_ENERGY(SPECIES(SP_ID2)%ROTDOF, MCC_BG_TTRA, EROT)
               CALL INTERNAL_ENERGY(SPECIES(SP_ID2)%VIBDOF, MCC_BG_TTRA, EVIB)
               CALL INIT_PARTICLE(particles(JP1)%X,particles(JP1)%Y,particles(JP1)%Z, &
               C2(1),C2(2),C2(3),EROT,EVIB,SP_ID2,particles(JP1)%IC,DT, NEWparticle)
               !WRITE(*,*) 'Should be adding particle!'
               CALL ADD_PARTICLE_ARRAY(NEWparticle, NP_PROC, particles)
               
               JP2 = NP_PROC

               M1    = SPECIES(SP_ID1)%MOLECULAR_MASS
               M2    = SPECIES(SP_ID2)%MOLECULAR_MASS
               MRED  = M1*M2/(M1+M2)
      
               ETR = 0.5*MRED*VR2

               ! Test for chemical reaction with TCE model
               ECOLL = ETR + particles(JP1)%EROT + particles(JP2)%EROT + &
               particles(JP1)%EVIB + particles(JP2)%EVIB
               SKIP = .FALSE.
               DO JR = 1, N_REACTIONS
                  ! Check if species in collision belong to this reaction.
                  ! If they don't, check the next reaction.
                  ! Not very efficient with many reactions
                  IF (REACTIONS(JR)%R1_SP_ID .NE. SP_ID1) THEN
                     IF (REACTIONS(JR)%R1_SP_ID .NE. SP_ID2) THEN
                        CYCLE
                     ELSE
                        IF (REACTIONS(JR)%R2_SP_ID .NE. SP_ID1) CYCLE
                     END IF
                  ELSE
                     IF (REACTIONS(JR)%R2_SP_ID .NE. SP_ID2) CYCLE
                  END IF
      
                  EA = REACTIONS(JR)%EA
                  IF (ECOLL .LE. EA) CYCLE
                  rfp = rf()
                  PTCE = REACTIONS(JR)%C1 * (ECOLL-EA)**REACTIONS(JR)%C2 * (1.-EA/ECOLL)**REACTIONS(JR)%C3
                  ! Here we suppose that the probability is so low that we can test sequentially with acceptable error
                  IF (rfp .LT. PTCE) THEN
                     SKIP = .TRUE.
                     ! React
                     ECOLL = ECOLL - EA

                     ! Use R1 as P1 and assign internal energy to it.
                     ! Use R2 as P2 (or P2+P3) (Set R2 as the molecule that dissociates in P2+P3)
                     P1_SP_ID = REACTIONS(JR)%P1_SP_ID
                     P2_SP_ID = REACTIONS(JR)%P2_SP_ID

                     particles(JP1)%S_ID = REACTIONS(JR)%P1_SP_ID
                     particles(JP2)%S_ID = REACTIONS(JR)%P2_SP_ID

                     IF (.NOT. REACTIONS(JR)%IS_CEX) THEN
         
                        TOTDOF = 3. + SPECIES(P2_SP_ID)%ROTDOF + SPECIES(P2_SP_ID)%VIBDOF + &
                              SPECIES(P1_SP_ID)%ROTDOF
                        IF (REACTIONS(JR)%N_PROD == 3) THEN
                           P3_SP_ID = REACTIONS(JR)%P3_SP_ID
                           TOTDOF = TOTDOF + 3. + SPECIES(P3_SP_ID)%ROTDOF + SPECIES(P3_SP_ID)%VIBDOF
                        END IF
         
                        EI = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, SPECIES(P1_SP_ID)%VIBDOF)
                        particles(JP1)%EVIB = EI
                        ECOLL = ECOLL - EI
         
                        TOTDOF = TOTDOF - SPECIES(P1_SP_ID)%ROTDOF
                        EI = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, SPECIES(P1_SP_ID)%ROTDOF)
                        particles(JP1)%EROT = EI
                        ECOLL = ECOLL - EI
         
                        TOTDOF = TOTDOF - SPECIES(P2_SP_ID)%VIBDOF
                        EI = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, SPECIES(P2_SP_ID)%VIBDOF)
                        particles(JP2)%EVIB = EI
                        ECOLL = ECOLL - EI
         
                        TOTDOF = TOTDOF - SPECIES(P2_SP_ID)%ROTDOF
                        EI = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, SPECIES(P2_SP_ID)%ROTDOF)
                        particles(JP2)%EROT = EI
                        ECOLL = ECOLL - EI
         
                        M1 = SPECIES(P1_SP_ID)%MOLECULAR_MASS
                        IF (REACTIONS(JR)%N_PROD == 2) THEN
                           M2 = SPECIES(P2_SP_ID)%MOLECULAR_MASS
                        ELSE IF (REACTIONS(JR)%N_PROD == 3) THEN
                           M2 = SPECIES(P2_SP_ID)%MOLECULAR_MASS + SPECIES(P3_SP_ID)%MOLECULAR_MASS
                        END IF
                        TOTDOF = TOTDOF - 3.
                        EI = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, 3)
                        CALL HS_SCATTER(EI, M1, M2, C1, C2)
                        ECOLL = ECOLL - EI
         
                        particles(JP1)%VX = C1(1)
                        particles(JP1)%VY = C1(2)
                        particles(JP1)%VZ = C1(3)

         
                        IF (REACTIONS(JR)%N_PROD == 2) THEN
                           particles(JP2)%VX = C2(1)
                           particles(JP2)%VY = C2(2)
                           particles(JP2)%VZ = C2(3)
                        ELSE IF (REACTIONS(JR)%N_PROD == 3) THEN
                           TOTDOF = TOTDOF - SPECIES(P3_SP_ID)%VIBDOF
                           EVIB = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, SPECIES(P3_SP_ID)%VIBDOF)
                           ECOLL = ECOLL - EVIB
               
                           TOTDOF = TOTDOF - SPECIES(P3_SP_ID)%ROTDOF
                           EROT = COLL_INTERNAL_ENERGY(ECOLL, TOTDOF, SPECIES(P3_SP_ID)%ROTDOF)
                           ECOLL = ECOLL - EROT
            
                           M1 = SPECIES(P2_SP_ID)%MOLECULAR_MASS
                           M2 = SPECIES(P3_SP_ID)%MOLECULAR_MASS
                           C1 = C2
                           
                           CALL HS_SCATTER(ECOLL, M1, M2, C1, C2)
                                 
                           particles(JP2)%VX = C1(1)
                           particles(JP2)%VY = C1(2)
                           particles(JP2)%VZ = C1(3)
                                 
                           
                           CALL INIT_PARTICLE(particles(JP2)%X,particles(JP2)%Y,particles(JP2)%Z, &
                           C2(1),C2(2),C2(3),EROT,EVIB,P3_SP_ID,particles(JP2)%IC,DT, NEWparticle)
                           !WRITE(*,*) 'Should be adding particle!'
                           CALL ADD_PARTICLE_ARRAY(NEWparticle, NP_PROC, particles)
                           
                        
                        END IF
                     END IF

                     ! If this pair had a chemical reaction, exit and don't test any other reaction.
                     EXIT

                  END IF
               END DO
      
               IF (SKIP) CYCLE
               ! Perform elastic/inelastic collision
               ! Test for inelastic collision and TR/TV exchange
               TRDOF = 3.
      
               !TRDOF = 5. -2.*OMEGA why not?
      
               PROT1 = (TRDOF + SPECIES(SP_ID1)%ROTDOF)/TRDOF * SPECIES(SP_ID1)%ROTREL
               PROT2 = (TRDOF + SPECIES(SP_ID2)%ROTDOF)/TRDOF * SPECIES(SP_ID2)%ROTREL
               PVIB1 = (TRDOF + SPECIES(SP_ID1)%VIBDOF)/TRDOF * SPECIES(SP_ID1)%VIBREL
               PVIB2 = (TRDOF + SPECIES(SP_ID2)%VIBDOF)/TRDOF * SPECIES(SP_ID2)%VIBREL
      
               TRDOF = 5. -2.*OMEGA
      
               rfp = rf()
               IF (rfp .LT. PROT1) THEN
                  ! Particle 1 selected for rotational energy exchange
                  ECOLL = ETR + particles(JP1)%EROT
                  particles(JP1)%EROT = COLL_INTERNAL_ENERGY(ECOLL, TRDOF, SPECIES(SP_ID1)%ROTDOF)
                  ETR = ECOLL - particles(JP1)%EROT
      
               ELSE IF (rfp .LT. PROT1 + PROT2) THEN
                  ! Particle 2 selected for rotational energy exchange
                  ECOLL = ETR + particles(JP2)%EROT
                  particles(JP2)%EROT = COLL_INTERNAL_ENERGY(ECOLL, TRDOF, SPECIES(SP_ID2)%ROTDOF)
                  ETR = ECOLL - particles(JP2)%EROT
      
               ELSE IF (rfp .LT. PROT1 + PROT2 + PVIB1) THEN
                  ! Particle 1 selected for vibrational energy exchange
                  ECOLL = ETR + particles(JP1)%EVIB
                  particles(JP1)%EVIB = COLL_INTERNAL_ENERGY(ECOLL, TRDOF, SPECIES(SP_ID1)%VIBDOF)
                  ETR = ECOLL - particles(JP1)%EVIB
      
               ELSE IF (rfp .LT. PROT1 + PROT2 + PVIB1 + PVIB2) THEN
                  ! Particle 2 selected for vibrational energy exchange
                  ECOLL = ETR + particles(JP2)%EVIB
                  particles(JP2)%EVIB = COLL_INTERNAL_ENERGY(ECOLL, TRDOF, SPECIES(SP_ID2)%VIBDOF)
                  ETR = ECOLL - particles(JP2)%EVIB
      
               END IF
      
               ! Compute post-collision velocities
               ! VSS Collisions
      
               COSCHI = 2.*rf()**(1./ALPHA) - 1.
               SINCHI = SQRT(1.-COSCHI*COSCHI)
               THETA = PI2*rf()
               COSTHETA = COS(THETA)
               SINTHETA = SIN(THETA)
      
      
               IF (rfp .LT. PROT1 + PROT2 + PVIB1 + PVIB2) THEN
      
                  ! Inelastic collision occurred => Randomize relative velocity vector
                  G = SQRT(2.*ETR/MRED)
                  
                  COSA = 2.*rf()-1.0
                  SINA = SQRT(1-COSA*COSA)
                  BB = PI2 * rf()
      
                  GX = G*SINA*COS(BB)
                  GY = G*SINA*SIN(BB)
                  GZ = G*COSA
               
               ELSE
      
                  ! No inelastic collision occured => Take actual velocity vector
                  GX = C1(1) - C2(1)
                  GY = C1(2) - C2(2)
                  GZ = C1(3) - C2(3)
                  G = SQRT(GX*GX + GY*GY + GZ*GZ)
      
               END IF
      
               ! Compute post-collision velocities
      
               GREL(1) = GX*COSCHI + SQRT(GY*GY+GZ*GZ)*SINTHETA*SINCHI
               GREL(2) = GY*COSCHI + (G*GZ*COSTHETA - GX*GY*SINTHETA)/SQRT(GY*GY+GZ*GZ)*SINCHI
               GREL(3) = GZ*COSCHI - (G*GY*COSTHETA + GX*GZ*SINTHETA)/SQRT(GY*GY+GZ*GZ)*SINCHI
      
               ! Compute center of mass velocity vector
               DO I = 1, 3
                  W(I) = M1/(M1+M2)*C1(I) + M2/(M1+M2)*C2(I)
               END DO
      
               ! Compute absolute velocity vector of the two particles
               DO I = 1, 3
                  C1(I) = W(I) + M2/(M1+M2)*GREL(I)
                  C2(I) = W(I) - M1/(M1+M2)*GREL(I)
               END DO
      
               
               particles(JP1)%VX = C1(1)
               particles(JP1)%VY = C1(2)
               particles(JP1)%VZ = C1(3)
                           
               particles(JP2)%VX = C2(1)
               particles(JP2)%VY = C2(2)
               particles(JP2)%VZ = C2(3)
               
            END IF
         END DO
      END DO

   END SUBROUTINE MCC_COLLISIONS


END MODULE timecycle
